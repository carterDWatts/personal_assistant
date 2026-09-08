"""Durable APNs delivery. Delivery never implies the task was completed."""
import asyncio
import base64
import json
import os
import time
from datetime import datetime, timedelta, timezone

from engine import config
from engine.db import Map
from engine.reminders import next_time


def b64(data): return base64.urlsafe_b64encode(data).rstrip(b'=')


class Push:
    def __init__(self): self.cached = None
    def token(self):
        if self.cached and time.time() - self.cached[0] < 3000: return self.cached[1]
        from cryptography.hazmat.primitives.serialization import load_pem_private_key
        from cryptography.hazmat.primitives import hashes
        from cryptography.hazmat.primitives.asymmetric import ec, utils
        now = int(time.time())
        header = b64(json.dumps({'alg':'ES256','kid':os.environ['ASSISTANT_APNS_KEY_ID']}).encode())
        claims = b64(json.dumps({'iss':os.environ['ASSISTANT_APNS_TEAM_ID'],'iat':now}).encode())
        signed = header+b'.'+claims
        key = load_pem_private_key(os.environ['ASSISTANT_APNS_KEY'].encode(), password=None)
        r,s = utils.decode_dss_signature(key.sign(signed,ec.ECDSA(hashes.SHA256())))
        token = (signed+b'.'+b64(r.to_bytes(32,'big')+s.to_bytes(32,'big'))).decode()
        self.cached=(now,token)
        return token

    async def send(self, row):
        import httpx
        host = 'api.sandbox.push.apple.com' if row['environment']=='sandbox' else 'api.push.apple.com'
        payload = {'aps':{'alert':{'title':config.ASSISTANT_NAME,'body':row['title']},'sound':'default','category':'REMINDER','thread-id':'reminders'},
                   'reminder_id':str(row['reminder_id']),'version':row['version']}
        if row.get('notice'):
            payload = {'aps':{'alert':{'title':config.ASSISTANT_NAME,'body':row['title']},'sound':'default','thread-id':'attention'}, 'notice_id':str(row['reminder_id'])}
        async with httpx.AsyncClient(http2=True, timeout=10) as client:
            result = await client.post(f"https://{host}/3/device/{row['token']}", json=payload, headers={
                'authorization':'bearer '+self.token(),'apns-topic':'com.carterwatts.assistant',
                'apns-push-type':'alert','apns-priority':'10','apns-id':str(row['id']),
                'apns-collapse-id':str(row['reminder_id']),
                'apns-expiration':str(int(time.time()+3600))})
        return result.status_code, result.json().get('reason','') if result.content else ''


class Dispatcher:
    def __init__(self, map_, push=None): self.map=map_; self.push=push or Push()

    def queue(self):
        with self.map.conn.transaction():
            devices = self.map.rows("select p.device_id from assistant.push_devices p join assistant.devices d on d.id=p.device_id where p.enabled and d.revoked_at is null")
            if not devices: return
            due = self.map.rows("select * from memory.reminders where status='open' and next_notify_at<=now() order by next_notify_at for update skip locked limit 20")
            for reminder in due:
                self.map.execute('update assistant.reminder_deliveries set cancelled_at=now() where reminder_id=%s and sent_at is null and cancelled_at is null', (reminder['id'],))
                for device in devices:
                    self.map.execute("insert into assistant.reminder_deliveries(reminder_id,device_id,scheduled_at,version) values(%s,%s,%s,%s) on conflict do nothing",
                        (reminder['id'],device['device_id'],reminder['next_notify_at'],reminder['version']))
                hours=float(reminder['followup_hours'])
                now=datetime.now(timezone.utc)
                if reminder['window_end'] and reminder['window_end']<=now+timedelta(days=1): hours=min(hours,24)
                following=next_time(reminder['timing'],reminder['window_start'],hours,reminder['timezone'],now)
                self.map.execute('update memory.reminders set next_notify_at=%s where id=%s',(following,reminder['id']))

    async def deliver(self):
        # Keep each reminder locked through dispatch, so a committed cancellation cannot
        # race ahead of an unsent notification. Network timeout bounds the lock duration.
        with self.map.conn.transaction():
            row=self.map.row("select n.*,p.token,p.environment,p.enabled,d.revoked_at,r.title,r.status,r.version as current_version from assistant.reminder_deliveries n join assistant.push_devices p on p.device_id=n.device_id join assistant.devices d on d.id=n.device_id join memory.reminders r on r.id=n.reminder_id where n.sent_at is null and n.cancelled_at is null and n.retry_at<=now() order by n.retry_at for update of n,r skip locked limit 1")
            if not row: return False
            if row['status']!='open' or row['current_version']!=row['version'] or not row['enabled'] or row['revoked_at']:
                self.map.execute('update assistant.reminder_deliveries set cancelled_at=now() where id=%s',(row['id'],));return True
            try: status, reason=await self.push.send(row)
            except Exception: status,reason=503,'transport_unavailable'
            self.map.execute('update assistant.reminder_deliveries set attempts=attempts+1 where id=%s',(row['id'],))
            if status==200:
                self.map.execute('update assistant.reminder_deliveries set sent_at=now(),last_error=null where id=%s',(row['id'],))
            else:
                self.map.execute("update assistant.reminder_deliveries set last_error=%s,retry_at=now()+interval '5 minutes' where id=%s",(reason[:100],row['id']))
                if reason in ('BadDeviceToken','Unregistered','DeviceTokenNotForTopic'):
                    self.map.execute('update assistant.push_devices set enabled=false where device_id=%s and token=%s',(row['device_id'],row['token']))
            return True


    async def attention(self):
        self.map.execute("insert into assistant.attention_deliveries(notice_id,device_id) select a.id,p.device_id from assistant.attention a cross join assistant.push_devices p join assistant.devices d on d.id=p.device_id where a.notify and a.created_at>now()-interval '1 day' and p.enabled and d.revoked_at is null on conflict do nothing")
        with self.map.conn.transaction():
            row=self.map.row("select n.id,n.notice_id as reminder_id,n.device_id,p.token,p.environment,a.title,a.detail,a.source,a.source_id from assistant.attention_deliveries n join assistant.attention a on a.id=n.notice_id join assistant.push_devices p on p.device_id=n.device_id join assistant.devices d on d.id=n.device_id where n.sent_at is null and n.cancelled_at is null and n.retry_at<=now() and p.enabled and d.revoked_at is null order by n.retry_at for update of n skip locked limit 1")
            if not row: return False
            try:
                if row['source']=='gmail':
                    from engine.integrations.google import _get, GoogleRequestError
                    try:
                        fresh=await asyncio.to_thread(_get,'gmail/v1/users/me/messages/'+row['source_id'],{'format':'minimal'})
                        unread='UNREAD' in fresh.get('labelIds',[])
                    except GoogleRequestError as error:
                        if error.status != 404: raise
                        unread=False
                    if not unread:
                        self.map.execute('update assistant.attention_deliveries set cancelled_at=now() where id=%s',(row['id'],)); return True
                row.update(notice=True,version=1,title=(row['title']+' — '+row['detail'])[:500])
                status,reason=await self.push.send(row)
            except Exception: status,reason=503,'transport_unavailable'
            if status==200:
                self.map.execute('update assistant.attention_deliveries set sent_at=now(),last_error=null where id=%s',(row['id'],))
            else:
                self.map.execute("update assistant.attention_deliveries set last_error=%s,retry_at=now()+interval '5 minutes' where id=%s",(reason[:100],row['id']))
                if reason in ('BadDeviceToken','Unregistered','DeviceTokenNotForTopic'):
                    self.map.execute('update assistant.push_devices set enabled=false where device_id=%s and token=%s',(row['device_id'],row['token']))
            return True


async def run(url, host):
    await host.ready.wait()
    map_=Map(url)
    dispatcher=Dispatcher(map_)
    try:
        while not host.stopping.is_set():
            try:
                if os.environ.get('ASSISTANT_APNS_KEY') and map_.value('select exists(select 1 from assistant.host where worker_id=%s and lease_until>now())',(host.relay.worker_id,)):
                    dispatcher.queue()
                    for _ in range(20):
                        if not await dispatcher.deliver(): break
                    for _ in range(10):
                        if not await dispatcher.attention(): break
                    await host.refresh_day()
            except Exception:
                # The queue remains durable; host logs show failure without notification contents.
                print('Reminder delivery will retry.', flush=True)
            try: await asyncio.wait_for(host.stopping.wait(),30)
            except asyncio.TimeoutError: pass
    finally: map_.close()
