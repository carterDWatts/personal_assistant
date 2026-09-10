"""Continue submitted code through CI and a verified iPhone release without a model."""
import asyncio
import os
from datetime import datetime, timedelta, timezone
from engine.db import jsonb
from engine.development import Development
from engine.tools import ToolError


def can_ship(files):
    # Automatic delivery is deliberately narrower than owner development access.
    return bool(files) and any(p.startswith('ios/Assistant/') for p in files) and all(
        (p.startswith(('ios/Assistant/', 'ios/AssistantTests/', 'ios/AssistantUITests/', 'shared/')) and p.endswith('.swift'))
        or (p.startswith('tst/') and p.endswith('.py')) for p in files)


class Delivery:
    def __init__(self, tools, job):
        self.map=tools.map; self.job=job; self.dev=Development(tools)

    def save(self, state):
        state={**state,'next_check':(datetime.now(timezone.utc)+timedelta(seconds=30)).isoformat()}
        self.map.execute("update assistant.jobs set artifacts=artifacts || %s where id=%s and status='running'",
                         (jsonb({'delivery':state}),self.job['id']))
        return state

    async def submit(self, workspace, args):
        existing=self.map.value("select artifacts->'delivery' from assistant.jobs where id=%s",(self.job['id'],))
        if existing:return existing
        files={p:c for p,c in workspace.files.items() if workspace.original.get(p)!=c}
        if not files:raise ToolError('No source files changed. A prose patch is not an implementation.')
        if not workspace.base_sha:raise ToolError('Read the current repository before submitting.')
        request={**args,'files':files,'base_sha':workspace.base_sha}
        # Retain complete files before publication; failures do not lose the draft.
        self.map.execute("update assistant.jobs set artifacts=artifacts || %s where id=%s",
                         (jsonb({'workspace':workspace.checkpoint(),'submission':request}),self.job['id']))
        self.dev.publication_key=str(self.job['id'])
        review=await self.dev.publish(request)
        requested=self.map.value("select role='user' from memory.messages where id=%s",(self.job['message_id'],))
        state={'phase':'checks','review':review,'summary':args['title'],
               'automatic':os.environ.get('ASSISTANT_DEVELOPMENT_AUTOSHIP')=='1' and requested
                   and not self.job['task_key'].startswith(('proactive:','development:')) and can_ship(files),
               'started_at':datetime.now(timezone.utc).isoformat()}
        return self.save(state)

    async def advance(self, finish):
        state=self.map.value("select artifacts->'delivery' from assistant.jobs where id=%s",(self.job['id'],))
        if not state:return False
        review=state['review']
        def done(status,message):
            finish(self.job,status,message,{'delivery':{**state,'phase':status}})
        if not state['automatic'] or os.environ.get('ASSISTANT_DEVELOPMENT_AUTOSHIP')!='1':
            done('completed','I prepared a pull request for review: '+review['url']+'. It has not been merged or deployed. Automatic delivery is limited to iPhone source changes.')
            return True
        if datetime.now(timezone.utc)-datetime.fromisoformat(state['started_at'])>timedelta(hours=2):
            done('failed','The release has not completed within two hours. The saved PR and release status are available at '+review['url']+'.')
            return True
        try:
            pr=await asyncio.to_thread(self.dev.github,'pulls/'+str(review['number']))
            if pr['head']['sha']!=review['sha']:
                done('failed','The proposed revision changed. I stopped automatic delivery for review: '+review['url'])
                return True
            if state['phase']=='checks':
                if pr.get('merged'):
                    state.update(phase='release',merge_sha=pr['merge_commit_sha'])
                elif pr['state']!='open':
                    done('failed','The pull request was closed without merging: '+review['url']);return True
                else:
                    checks=(await self.dev.status({'number':review['number']}))['checks']
                    required=[c for c in checks if c['name'] in ('assistant-tests','assistant-apps')]
                    if any(c['status']=='completed' and c['conclusion']!='success' for c in required):
                        done('failed','The proposed change did not pass CI. I kept the PR for repair: '+review['url']);return True
                    if not all(any(c['name']==n and c['status']=='completed' and c['conclusion']=='success' for c in required) for n in ('assistant-tests','assistant-apps')):
                        self.save(state);return True
                    # Recheck file scope from GitHub before merging the exact tested revision.
                    files=await asyncio.to_thread(self.dev.github,'pulls/'+str(review['number'])+'/files?per_page=100')
                    if not can_ship([f['filename'] for f in files]) or len(files)>=100:
                        done('failed','This change needs owner review before deployment: '+review['url']);return True
                    if self.map.value('select status from assistant.jobs where id=%s',(self.job['id'],))!='running':return True
                    result=await self.dev.merge({'number':review['number'],'sha':review['sha']})
                    if not result.get('merged'):raise ToolError('Merge did not complete.')
                    state.update(phase='release',merge_sha=result['sha'])
                self.save(state)
            if state['phase']=='release':
                runs=await asyncio.to_thread(self.dev.github,'actions/workflows/release-ios.yml/runs?head_sha='+state['merge_sha']+'&event=push&per_page=5')
                runs=runs.get('workflow_runs',[])
                if not runs or runs[0]['status']!='completed':self.save(state);return True
                if runs[0]['conclusion']!='success':
                    done('failed','The code merged, but I could not verify the completed iPhone release. Build details: '+runs[0]['html_url']);return True
                release=await asyncio.to_thread(self.dev.github,'releases/tags/ios-'+state['merge_sha'])
                done('completed','An iPhone update is ready in TestFlight. '+state['summary']+'\n\n'+release['body']+'\n\n'+release['html_url'])
        except Exception as error:
            # Provider outages retry from the saved phase, without another model call.
            self.save({**state,'last_error':type(error).__name__})
        return True
