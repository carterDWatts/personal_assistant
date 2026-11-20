"""Price watches use published structured offers and deterministic thresholds."""
import asyncio
import hashlib
import json
from decimal import Decimal, InvalidOperation
from html.parser import HTMLParser
from datetime import datetime,timezone
from engine.db import Map,jsonb
from engine.tools import ToolError,ToolSpec,_obj
from engine.integrations.web import open_public

class Offers(HTMLParser):
    def __init__(self):super().__init__();self.active=False;self.parts=[];self.documents=[]
    def handle_starttag(self,tag,attrs):
        if tag=='script' and dict(attrs).get('type','').lower()=='application/ld+json':self.active=True;self.parts=[]
    def handle_data(self,data):
        if self.active:self.parts.append(data)
    def handle_endtag(self,tag):
        if tag=='script' and self.active:
            self.active=False
            try:self.documents.append(json.loads(''.join(self.parts)))
            except ValueError:pass


def inspect(args):
    with open_public(args['url'],https_only=True) as (url,response):
        if response.status!=200:raise ToolError('This page could not be checked. No price was inferred.')
        raw=response.read(1_000_001)
        if len(raw)>1_000_000:raise ToolError('Page too large for a bounded price check.')
    parser=Offers();parser.feed(raw.decode('utf-8',errors='replace'))
    found=[]
    def visit(value):
        if isinstance(value,list):
            for x in value:visit(x)
        elif isinstance(value,dict):
            types=value.get('@type',[]);types=[types] if isinstance(types,str) else types
            if 'Product' in types:
                offers=value.get('offers',[]);offers=offers if isinstance(offers,list) else [offers]
                for offer in offers:
                    if not isinstance(offer,dict) or 'price' not in offer or not offer.get('priceCurrency'):continue
                    try:price=Decimal(str(offer['price']))
                    except InvalidOperation:continue
                    if not price.is_finite() or price<0:continue
                    name=str(value.get('name',''))[:300];sku=str(value.get('sku',''))[:200]
                    currency=str(offer['priceCurrency']).upper()
                    identity=json.dumps([name,sku,currency,offer.get('url',''),offer.get('seller',{})],sort_keys=True)
                    found.append({'key':hashlib.sha256(identity.encode()).hexdigest(),'name':name,'sku':sku,'price':str(price),
                                  'currency':currency,'availability':offer.get('availability'),'url':url})
            for key,item in value.items():
                if key!='offers':visit(item)
    visit(parser.documents)
    return {'url':url,'offers':found[:20],'fetched_at':datetime.now(timezone.utc).isoformat(),
            'note':'Published structured offers, not checkout prices. Shipping, tax, membership discounts and variant selection may differ. No offer means unknown, not unavailable.'}


class Watches:
    def __init__(self,tools):self.map=tools.map
    async def save(self,args):
        current=await asyncio.to_thread(inspect,args)
        matches=[x for x in current['offers'] if x['key']==args['offer_key']]
        if len(matches)!=1:raise ToolError('Inspect the page and select one unambiguous offer first.')
        offer=matches[0]
        row=self.map.row("insert into assistant.price_watches(url,offer_key,title,currency,threshold,last_price) values(%s,%s,%s,%s,%s,%s) on conflict(url,offer_key) do update set generation=assistant.price_watches.generation+1,threshold=excluded.threshold,enabled=true,expires_at=now()+interval '90 days',next_check=now(),notified_at=null returning id,threshold,currency,next_check,expires_at",(args['url'],args['offer_key'],offer['name'],offer['currency'],Decimal(args['below']),Decimal(offer['price'])))
        return {'watch':row,'note':'Checks hourly for up to 90 days. One notification when the threshold is met; no purchase is made.'}
    async def list(self,args):return self.map.rows('select id,url,title,currency,threshold,last_price,last_checked,last_error,enabled,expires_at,notified_at from assistant.price_watches order by created_at desc limit 100')
    async def cancel(self,args):return self.map.row('update assistant.price_watches set enabled=false where id=%s returning id,enabled',(args['id'],)) or {'error':'Watch not found'}
    def specs(self):
        s={'type':'string','minLength':1,'maxLength':2048}
        async def read(args):return await asyncio.to_thread(inspect,args)
        return [ToolSpec('product_offers','Read structured product prices from a public HTTPS page. No sign-in or purchases. Select an exact offer before creating a watch; no supported offer means unknown.',_obj({'url':s},['url']),read),
            ToolSpec('price_watch','Watch a selected product offer hourly and notify once its published price is at or below the threshold. Currency comes from the offer. Expires after 90 days; no purchase.',_obj({'url':s,'offer_key':s,'below':{'type':'string','pattern':'^[0-9]{1,9}(\\.[0-9]{1,4})?$'}},['url','offer_key','below']),self.save),
            ToolSpec('price_watches','List price watches, freshness and failures.',_obj({},[]),self.list),
            ToolSpec('price_watch_cancel','Stop a price watch.',_obj({'id':{'type':'string','format':'uuid'}},['id']),self.cancel)]


async def poll(map_):
    if not map_.value("select pg_try_advisory_lock(hashtextextended('price-watches',0))"):return
    try:
        for row in map_.rows("select * from assistant.price_watches where enabled and notified_at is null and expires_at>now() and next_check<=now() order by next_check limit 5"):
            try:
                data=await asyncio.to_thread(inspect,{'url':row['url']})
                matches=[x for x in data['offers'] if x['key']==row['offer_key'] and x['currency']==row['currency']]
                if len(matches)!=1:raise ToolError('The saved offer is no longer identifiable.')
                price=Decimal(matches[0]['price'])
                with map_.conn.transaction():
                    active=map_.row('select * from assistant.price_watches where id=%s for update',(row['id'],))
                    if not active['enabled'] or active['notified_at'] or active['expires_at']<=datetime.now(timezone.utc):continue
                    map_.execute("update assistant.price_watches set last_price=%s,last_checked=now(),last_error=null,next_check=now()+interval '1 hour' where id=%s",(price,row['id']))
                    if price<=active['threshold']:
                        from engine.outbound import post
                        post(map_,'price-watch:'+str(row['id'])+':'+str(active['generation']),f"{row['title']} is listed at {price} {row['currency']}, within your target. Check the exact option, shipping and tax before buying.\n{row['url']}",{'kind':'price_watch','id':str(row['id'])})
                        map_.execute('update assistant.price_watches set notified_at=now() where id=%s',(row['id'],))
            except Exception:
                map_.execute("update assistant.price_watches set last_checked=now(),last_error='Could not verify the saved offer; no price inferred.',next_check=now()+interval '1 hour' where id=%s",(row['id'],))
    finally:map_.execute("select pg_advisory_unlock(hashtextextended('price-watches',0))")


async def run(url,host):
    await host.ready.wait();map_=Map(url)
    try:
        while not host.stopping.is_set():
            await poll(map_)
            try:await asyncio.wait_for(host.stopping.wait(),60)
            except asyncio.TimeoutError:pass
    finally:map_.close()
