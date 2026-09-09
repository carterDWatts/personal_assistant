"""Supabase operations exposed to the assistant."""
from urllib.parse import quote

from engine.integrations.accounts import _request
from engine.integrations.results import snapshot as _result, tool


def _supabase_projects(args):
    data=_request('supabase','projects')
    return _result(projects=[{k:r.get(k) for k in ('id','name','organization_id','region','status','created_at')} for r in data])


def _supabase_project(args):
    ref=quote(args['project'],safe='')
    if args['kind']=='schema':
        return _result(schema=_request('supabase','projects/'+ref+'/types/typescript',params={'included_schemas':args.get('schemas','public')}))
    data=_request('supabase','projects/'+ref+('/functions' if args['kind']=='functions' else ''))
    keys=('id','name','slug','status','version','created_at','updated_at') if args['kind']=='functions' else ('id','name','organization_id','region','status','created_at')
    return _result(data=[{k:r.get(k) for k in keys} for r in data] if isinstance(data,list) else {k:data.get(k) for k in keys})


def specs():
    return [
        tool('supabase_projects','Connect the user’s Supabase account and list its projects and current health. Not the assistant memory connection.',_supabase_projects,{}),
        tool('supabase_project_read','Read a Supabase project’s current metadata, deployed functions, or schema types. No SQL execution or secret access.',_supabase_project,{'project':{'type':'string','pattern':'^[a-z0-9]{20}$'},'kind':{'enum':['metadata','functions','schema']},'schemas':{'type':'string','pattern':'^[A-Za-z0-9_,]{1,200}$'}},['project','kind'])
    ]
