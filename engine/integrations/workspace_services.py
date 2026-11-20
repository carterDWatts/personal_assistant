"""Narrow Notion and Todoist writes through the shared operation journal."""
from urllib.parse import quote
from engine.tools import ToolSpec, ToolError, _obj
from engine.integrations.accounts import _request


def notion(args):
    rich=[{'type':'text','text':{'content':args['text']}}]
    paragraph={'object':'block','type':'paragraph','paragraph':{'rich_text':rich}}
    if args['action']=='create':
        return _request('notion','pages',body={'parent':{'page_id':args['parent_id']},
            'properties':{'title':{'type':'title','title':[{'type':'text','text':{'content':args['title']}}]}},'children':[paragraph]})
    identifier=quote(args['block_id'],safe='')
    if args['action']=='append':return _request('notion',f'blocks/{identifier}/children',method='PATCH',body={'children':[paragraph]})
    old=_request('notion',f'blocks/{identifier}')
    if old.get('last_edited_time')!=args['expected_edited_at']:raise ToolError('This block changed. Read it again before replacing it.')
    if old.get('type')!='paragraph':raise ToolError('This edit supports paragraph blocks only; no other block types were changed.')
    return _request('notion',f'blocks/{identifier}',method='PATCH',body={'paragraph':{'rich_text':rich}})


def todoist(args):
    body={k:args[k] for k in ('content','description','project_id','due_string','priority') if k in args}
    if args['action']=='create':return _request('todoist','tasks',body=body)
    path='tasks/'+quote(args['task_id'],safe='')
    if args['action'] in ('complete','reopen'):
        _request('todoist',path+('/close' if args['action']=='complete' else '/reopen'),method='POST')
        return {'task_id':args['task_id'],'status':'completed' if args['action']=='complete' else 'active'}
    return _request('todoist',path,method='POST',body=body)


def specs(journal):
    s={'type':'string','minLength':1,'maxLength':500}
    definitions=[('notion_edit',notion,{'action':{'enum':['create','append','replace_paragraph']},'title':s,'parent_id':s,'block_id':s,'expected_edited_at':s,'text':{'type':'string','maxLength':2000}},
        {'create':['title','parent_id','text'],'append':['block_id','text'],'replace_paragraph':['block_id','text','expected_edited_at']},
        'Create a child Notion page, append a paragraph or replace an existing paragraph. Read existing content first. Requires insert/update access in the Notion connection. No publishing, sharing or deleting. Replacement checks last edit time but the API has no atomic compare-and-swap.'),
      ('todoist_edit',todoist,{'action':{'enum':['create','update','complete','reopen']},'task_id':s,'project_id':s,'content':s,'description':{'type':'string','maxLength':10000},'due_string':s,'priority':{'type':'integer','minimum':1,'maximum':4}},
       {'create':['content'],'update':['task_id'],'complete':['task_id'],'reopen':['task_id']},
       'Create, update, complete or reopen a Todoist task when asked. Read the current task before editing. No deletions. priority 4 is most urgent.')]
    result=[]
    for name,fn,props,required,description in definitions:
        async def call(args,name=name,fn=fn,required=required):
            if any(k not in args for k in required[args['action']]):raise ToolError('Missing fields: '+', '.join(required[args['action']]))
            return await journal.execute(name,fn,args)
        result.append(ToolSpec(name,description,_obj(props,['action']),call))
    return result
