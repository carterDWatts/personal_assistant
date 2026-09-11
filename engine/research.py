"""Persist research coverage and require an explicit, supported end state."""
from engine.db import jsonb
from engine.tools import ToolSpec, ToolError, _obj, _s


class Research:
    def __init__(self, map_, job):
        self.map, self.job = map_, job
        self.result = None

    def state(self):
        return self.map.value("select artifacts->'research' from assistant.jobs where id=%s", (self.job['id'],)) or {'items': {}}

    def save(self, state):
        changed = self.map.execute("update assistant.jobs set artifacts=artifacts || %s where id=%s and status='running'", (jsonb({'research': state}), self.job['id']))
        if not changed: raise ToolError('This task is no longer running.')
        self.result = None
        return state

    async def plan(self, args):
        state = self.state()
        for item in args['items']:
            existing = state['items'].get(item['key'])
            if existing and existing['task'] != item['task']:
                raise ToolError('Keep existing checklist items intact. Add a new item for additional scope.')
            state['items'].setdefault(item['key'], {**item, 'status': 'pending'})
        if len(state['items']) > 100: raise ToolError('Split the scope into at most 100 meaningful work items.')
        self.save(state)
        return {'items':[{k:item[k] for k in ('key','task','status')} for item in state['items'].values()]}

    async def step(self, args):
        state = self.state()
        if args['key'] not in state['items']: raise ToolError('Add this item to the checklist first.')
        state['items'][args['key']].update(status=args['status'], evidence=args['evidence'])
        self.save(state)
        return {'item':state['items'][args['key']], 'remaining':sum(i['status']!='done' for i in state['items'].values())}

    async def finish(self, args):
        state = self.state()
        items = list(state['items'].values())
        if not items: raise ToolError('Record the requested coverage in job_plan before reporting completion.')
        if any(i['status'] == 'pending' for i in items):
            raise ToolError('Unfinished checklist items remain. Continue them and save a checkpoint before stopping.')
        blocked = [i for i in items if i['status'] == 'blocked']
        self.result = ('failed' if blocked else 'completed', args['message'])
        return {'status': 'blocked' if blocked else 'completed', 'blocked': blocked}

    def specs(self):
        return [
            ToolSpec('job_plan', 'Record ALL requested research coverage before researching. Use one item per company, document, or deliverable. Existing items cannot be removed or silently replaced; this is the durable checklist used to verify completion.',
                _obj({'items': {'type':'array','minItems':1,'maxItems':100,'items':_obj({'key':_s('stable item key',minLength=1,maxLength=100),'task':_s('required coverage',minLength=1,maxLength=600)},['key','task'])}},['items']), self.plan),
            ToolSpec('job_step', 'Record verified findings and source references for a checklist item. Done means its requested investigation is finished. A guessed URL, unreadable page, or ambiguous identity is not a negative finding: try another source, then mark blocked with the exact missing evidence if genuinely stuck. Keep unfinished work pending.',
                _obj({'key':_s('item key'),'status':_s('coverage state',enum=['pending','done','blocked']),'evidence':_s('findings with source references, or the concrete blocker',minLength=1,maxLength=4000)},['key','status','evidence']), self.step),
            ToolSpec('job_finish', 'Submit the final first-person result after updating every checklist item. Pending work prevents completion; blocked items make the task incomplete, never successful. Clearly state any missing evidence and what is needed. A plain text reply alone does not finish the task.',
                _obj({'message':_s('result for the user',minLength=1,maxLength=12000)},['message']), self.finish)]
