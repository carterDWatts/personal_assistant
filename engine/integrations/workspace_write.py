"""Explicit workspace mutations, journaled separately from model tool execution."""
import asyncio
import hashlib
import json
from urllib.parse import quote
from engine.db import jsonb
from engine.tools import ToolSpec, ToolError, ConnectionRequired, _obj
from engine.integrations import google

SCOPE='https://www.googleapis.com/auth/'


def request(slot, method, api, path, body=None, params=None):
    scopes={'google_documents_write':[SCOPE+'documents',SCOPE+'spreadsheets',SCOPE+'drive.file'],
            'google_tasks_write':[SCOPE+'tasks']}[slot]
    credentials=google._credentials(slot)
    if not credentials or not credentials.has_scopes(scopes):
        raise ConnectionRequired('Approve editing access so I can make that change.',slot)
    google.refresh(credentials,slot)
    with google.AuthorizedSession(credentials) as client:
        response=client.request(method,f'https://{api}.googleapis.com/{path}',json=body,params=params,timeout=20,allow_redirects=False,stream=True)
        if response.status_code==401:raise ConnectionRequired('Please reconnect editing access.',slot)
        if response.status_code in (400,409,412):raise ToolError('The provider rejected this change. Read the item again; do not repeat the same edit blindly.')
        if not response.ok:raise ToolError(f'Google could not confirm the change (HTTP {response.status_code}). Check the item before retrying.')
        data=bytearray()
        for chunk in response.iter_content(8192):
            data.extend(chunk)
            if len(data)>512000:raise ToolError('Response too large. Request a smaller item.')
        return json.loads(data) if data else {}


def documents(args):
    slot='google_documents_write';action=args['action'];identifier=quote(args.get('document_id',''),safe='')
    if action=='read':return request(slot,'GET','docs',f'v1/documents/{identifier}')
    if action=='create':
        result=request(slot,'POST','docs','v1/documents',{'title':args['title']})
        identifier=result['documentId']
        try:
            if args.get('text'):request(slot,'POST','docs',f'v1/documents/{identifier}:batchUpdate',{'requests':[{'insertText':{'endOfSegmentLocation':{},'text':args['text']}}]})
        except Exception:
            return {'document_id':identifier,'url':f'https://docs.google.com/document/d/{identifier}/edit','partial':True,
                    'error':'The document exists, but adding its text was not confirmed. Read it before editing; do not create another.'}
        return {'document_id':identifier,'url':f'https://docs.google.com/document/d/{identifier}/edit'}
    if not args.get('revision_id'):raise ToolError('Read the document and supply its revision_id before editing.')
    if action=='append':edit={'insertText':{'endOfSegmentLocation':{},'text':args['text']}}
    else:edit={'replaceAllText':{'containsText':{'text':args['find'],'matchCase':True},'replaceText':args['text']}}
    result=request(slot,'POST','docs',f'v1/documents/{identifier}:batchUpdate',{'writeControl':{'requiredRevisionId':args['revision_id']},'requests':[edit]})
    return {'document_id':identifier,'receipt':result,'url':f'https://docs.google.com/document/d/{identifier}/edit'}


def sheets(args):
    slot='google_documents_write';action=args['action']
    if action=='create':
        result=request(slot,'POST','sheets','v4/spreadsheets',{'properties':{'title':args['title']}})
        return {'spreadsheet_id':result['spreadsheetId'],'url':result['spreadsheetUrl']}
    path=f"v4/spreadsheets/{quote(args['spreadsheet_id'],safe='')}/values/{quote(args['range'],safe='')}"
    current=request(slot,'GET','sheets',path,params={'valueRenderOption':'FORMULA'})
    fingerprint=hashlib.sha256(json.dumps(current.get('values',[]),sort_keys=True).encode()).hexdigest()
    if action=='read':return {'values':current.get('values',[]),'range':current.get('range'),'fingerprint':fingerprint}
    if args.get('expected_fingerprint')!=fingerprint:raise ToolError('These cells changed or were not read first. Read the range again before editing.')
    # Sheets has no atomic conditional values update. Re-read narrows, but cannot eliminate, concurrent-edit races.
    result=request(slot,'PUT','sheets',path,{'range':args['range'],'majorDimension':'ROWS','values':args['values']},
                   {'valueInputOption':'RAW','includeValuesInResponse':'true'})
    return {'receipt':result,'concurrency_note':'Range checked immediately before writing; simultaneous external edits cannot be locked by the Sheets API.'}


def tasks(args):
    path='tasks/v1/lists/'+quote(args['list_id'],safe='')+'/tasks'
    if args['action']!='create':path+='/'+quote(args['task_id'],safe='')
    body={k:args[k] for k in ('title','notes','due') if k in args}
    if args['action'] in ('complete','reopen'):body['status']='completed' if args['action']=='complete' else 'needsAction'
    return request('google_tasks_write','POST' if args['action']=='create' else 'PATCH','tasks',path,body)


class WorkspaceWrites:
    def __init__(self,tools):self.tools=tools;self.map=tools.map

    async def execute(self,name,fn,args):
        if args['action']=='read':return await asyncio.to_thread(fn,args)
        if self.tools.message_id is None:raise ToolError('Workspace edits require an active conversation.')
        key=hashlib.sha256(json.dumps([self.tools.message_id,name,args],sort_keys=True).encode()).hexdigest()
        # Commit the claim before external I/O. A lost receipt is uncertain, never automatically replayed.
        with self.map.conn.transaction():
            inserted=self.map.row("insert into assistant.external_operations(key,operation) values(%s,%s) on conflict do nothing returning key",(key,name))
            if not inserted:
                old=self.map.row('select state,result from assistant.external_operations where key=%s',(key,))
                if old['state']=='completed':return old['result']
                raise ToolError('This change was already attempted without a confirmed receipt. Inspect the provider before making another change.')
        try:result=await asyncio.to_thread(fn,args)
        except ConnectionRequired:
            self.map.execute('delete from assistant.external_operations where key=%s',(key,))
            raise
        except BaseException:
            self.map.execute("update assistant.external_operations set state='uncertain' where key=%s",(key,))
            raise
        self.map.execute("update assistant.external_operations set state='completed',result=%s where key=%s",(jsonb(result),key))
        return result

    def specs(self):
        s={'type':'string','minLength':1,'maxLength':500};text={'type':'string','maxLength':40000}
        definitions=[('google_document_edit',documents,{'action':{'enum':['create','read','append','replace_text']},'title':s,'document_id':s,'revision_id':s,'text':text,'find':s},
            'Create, read, append to or replace exact text in Google Docs. Read first and pass revision_id for edits; replacement affects every exact match. Creates require title; append/replace require text. No sharing changes.'),
          ('google_spreadsheet_edit',sheets,{'action':{'enum':['create','read','write']},'title':s,'spreadsheet_id':s,'range':s,'expected_fingerprint':s,
           'values':{'type':'array','maxItems':100,'items':{'type':'array','maxItems':30,'items':{'type':['string','number','boolean'],'maxLength':2000}}}},
            'Create a spreadsheet or read/write a bounded A1 range. Read returns expected_fingerprint for writing; write requires it and values. Uses RAW values, so text never executes as formulas. No append or sharing changes.'),
          ('google_task_edit',tasks,{'action':{'enum':['create','update','complete','reopen']},'list_id':s,'task_id':s,'title':s,'notes':text,'due':{'type':'string','format':'date-time'}},
            'Create, update, complete or reopen Google Tasks when asked. list_id always required; task_id for existing tasks; title for create. Due date is a date, not a scheduled time.')]
        result=[]
        for name,fn,props,description in definitions:
            async def call(args,name=name,fn=fn):
                action=args['action']
                required=({'create':['title'],'read':['document_id'],'append':['document_id','text','revision_id'],'replace_text':['document_id','find','text','revision_id']} if fn==documents else
                    {'create':['title'],'read':['spreadsheet_id','range'],'write':['spreadsheet_id','range','values','expected_fingerprint']} if fn==sheets else
                    {'create':['list_id','title'],'update':['list_id','task_id'],'complete':['list_id','task_id'],'reopen':['list_id','task_id']})
                if any(k not in args for k in required[action]):raise ToolError('Missing fields: '+', '.join(required[action]))
                return await self.execute(name,fn,args)
            result.append(ToolSpec(name,description,_obj(props,['action']),call))
        from engine.integrations.workspace_services import specs
        return result + specs(self)
