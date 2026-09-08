"""Owner-scoped repository changes. Tests run away from production credentials."""
import asyncio
import base64
import os
import re
import uuid
from engine.tools import ToolSpec, ToolError, _obj, _s, _i
from engine.integrations.services import _request


def validate_files(files):
    from engine.workspace import Workspace
    validator=object.__new__(Workspace)
    if not files or len(files)>30:raise ToolError('Use 1–30 focused source changes.')
    for path,content in files.items():
        validator.path(path)
        if path=='scripts/test.sh':raise ToolError('The validation runner cannot modify its own checks.')
        if not isinstance(content,str) or len(content)>200000:raise ToolError('Source file is too large.')
        if re.search(r'(?:gh[pousr]_[A-Za-z0-9]{20,}|sbp_[a-f0-9]{20,}|-----BEGIN .*PRIVATE KEY-----)',content):
            raise ToolError('Remove credentials from the proposed source.')
    if sum(map(len,files.values()))>300000:raise ToolError('Keep the change below 300 KB.')


class Development:
    def __init__(self,tools):self.tools=tools;self.map=tools.map

    def scope(self):
        owner=os.environ.get('ASSISTANT_DEVELOPER_OWNER')
        repo=os.environ.get('ASSISTANT_DEVELOPER_REPO','')
        project=os.environ.get('ASSISTANT_DEVELOPER_PROJECT','')
        if not owner or str(self.map.value('select user_id from assistant.owner'))!=owner:
            raise ToolError('Owner development is not enabled for this installation.')
        if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+',repo) or not re.fullmatch(r'[a-z]{20}',project):
            raise ToolError('Owner development scope is not configured.')
        return repo,project

    def github(self,path,body=None,method=None):
        repo,_=self.scope()
        return _request('github','repos/'+repo+'/'+path,body=body,method=method)

    async def status(self,args):
        repo,project=self.scope()
        if args.get('number'):
            pr=await asyncio.to_thread(self.github,'pulls/'+str(args['number']))
            checks=await asyncio.to_thread(self.github,'commits/'+pr['head']['sha']+'/check-runs')
            return {'url':pr['html_url'],'state':pr['state'],'merged':pr['merged'],'sha':pr['head']['sha'],
                    'checks':[{'name':c['name'],'status':c['status'],'conclusion':c['conclusion']} for c in checks['check_runs']]}
        head=await asyncio.to_thread(self.github,'git/ref/heads/main')
        return {'repository':repo,'project':project,'base_sha':head['object']['sha'],'workflow':'publish branch, test, merge exact revision, deploy'}

    async def publish(self,args):
        self.scope();validate_files(args['files'])
        base=await asyncio.to_thread(self.github,'git/ref/heads/main')
        if base['object']['sha']!=args['base_sha']:raise ToolError('Main changed. Read the latest source and rebase your changes.')
        commit=await asyncio.to_thread(self.github,'git/commits/'+args['base_sha'])
        tree=await asyncio.to_thread(self.github,'git/trees',{'base_tree':commit['tree']['sha'],'tree':[
            {'path':p,'mode':'100644','type':'blob','content':c} for p,c in args['files'].items()]})
        saved=await asyncio.to_thread(self.github,'git/commits',{'message':args['title'],'tree':tree['sha'],'parents':[args['base_sha']]})
        branch='assistant/'+str(uuid.uuid4())
        await asyncio.to_thread(self.github,'git/refs',{'ref':'refs/heads/'+branch,'sha':saved['sha']})
        pr=await asyncio.to_thread(self.github,'pulls',{'title':args['title'],'body':args['description'],'head':branch,'base':'main'})
        return {'number':pr['number'],'url':pr['html_url'],'sha':saved['sha'],'status':'awaiting_tests','deployed':False}

    async def merge(self,args):
        pr=await asyncio.to_thread(self.github,'pulls/'+str(args['number']))
        repo,_=self.scope()
        if pr['head']['repo']['full_name']!=repo or not pr['head']['ref'].startswith('assistant/') or pr['base']['ref']!='main':
            raise ToolError('Only this installation’s assistant branches can be merged.')
        if pr['state']!='open' or pr['head']['sha']!=args['sha']:raise ToolError('The pull request changed or is closed.')
        checks=await asyncio.to_thread(self.github,'commits/'+args['sha']+'/check-runs')
        passed=all(any(c['name']==name and c['app']['slug']=='github-actions' and c['conclusion']=='success' for c in checks['check_runs']) for name in ('assistant-tests','assistant-apps'))
        if not passed:raise ToolError('The required tests have not passed for this exact revision.')
        result=await asyncio.to_thread(self.github,'pulls/'+str(args['number'])+'/merge',{'sha':args['sha'],'merge_method':'squash'},'PUT')
        return {'merged':result.get('merged',False),'sha':result.get('sha'),'deployment':'queued by repository integration; verify separately'}

    async def database_read(self,args):
        _,project=self.scope()
        return await asyncio.to_thread(_request,'supabase','projects/'+project+'/database/query/read-only',body={'query':args['query']})

    async def migrate(self,args):
        self.scope()
        match=re.fullmatch(r'supabase/migrations/([0-9]{14})_([a-z0-9_]+)\.sql',args['path'])
        if not match:raise ToolError('Use a timestamped SQL migration committed on main.')
        head=await asyncio.to_thread(self.github,'git/ref/heads/main')
        if head['object']['sha']!=args['sha']:raise ToolError('Main changed. Inspect the current revision before applying a migration.')
        data=await asyncio.to_thread(self.github,'contents/'+args['path']+'?ref='+args['sha'])
        if data.get('encoding')!='base64':raise ToolError('Migration contents unavailable.')
        sql=base64.b64decode(data['content']).decode()
        from pglast import parse_sql, ast
        statements=parse_sql(sql)
        if not statements or any(isinstance(x.stmt,(ast.TransactionStmt,ast.CopyStmt)) for x in statements):
            raise ToolError('Migrations cannot manage transactions or use COPY.')
        from urllib.parse import urlsplit
        _,project=self.scope()
        target=urlsplit(self.map.url)
        if project not in (target.hostname or '') and project not in (target.username or ''):
            raise ToolError('The database connection does not match the configured development project.')
        version,name=match.groups()
        with self.map.conn.transaction():
            self.map.execute("select pg_advisory_xact_lock(hashtextextended('owner-migrations',0))")
            if self.map.value('select exists(select 1 from supabase_migrations.schema_migrations where version=%s)',(version,)):
                return {'version':version,'status':'already_applied'}
            latest=self.map.value('select max(version) from supabase_migrations.schema_migrations')
            if latest and version<=latest:raise ToolError('Use a new migration after the latest applied version.')
            self.map.execute("set local statement_timeout='30s'")
            self.map.execute("set local lock_timeout='5s'")
            self.map.conn.execute(sql,prepare=False)
            self.map.execute('insert into supabase_migrations.schema_migrations(version,name,statements) values(%s,%s,%s)',(version,name,[sql]))
        return {'version':version,'status':'applied','source_sha':args['sha']}

    def specs(self):
        if not os.environ.get('ASSISTANT_DEVELOPER_OWNER'):return []
        self.scope()
        return [ToolSpec('development_database_migrate','Apply an owner-authorized SQL migration from the current main revision to this installation’s Supabase database. The change and migration record commit atomically. Never use for an unreviewed destructive change.',_obj({'path':_s('committed migration path'),'sha':_s('current main revision',pattern='^[a-f0-9]{40}$')},['path','sha']),self.migrate),
                ToolSpec('development_status','Inspect owner repository scope, current main revision, or PR test status.',_obj({'number':_i('pull request number',minimum=1)},[]),self.status),
                ToolSpec('development_publish','Publish owner-requested source changes to a branch and pull request. Never deploys untested code. Read current source first; files are complete replacements.',
                         _obj({'base_sha':_s('main revision read before editing',pattern='^[a-f0-9]{40}$'),'title':_s('terse commit sentence',maxLength=150),'description':_s('problem, change and validation',maxLength=4000),'files':{'type':'object','additionalProperties':{'type':'string'}}},['base_sha','title','description','files']),self.publish),
                ToolSpec('development_merge','Merge an owner-authorized change only after required tests pass for the supplied revision. This triggers the configured production deployment.',_obj({'number':_i('PR number',minimum=1),'sha':_s('tested revision',pattern='^[a-f0-9]{40}$')},['number','sha']),self.merge),
                ToolSpec('development_database_read','Inspect the owner’s configured Supabase project using the provider’s read-only SQL endpoint. Never request credentials or authentication data.',_obj({'query':_s('bounded diagnostic SQL',maxLength=12000)},['query']),self.database_read)]
