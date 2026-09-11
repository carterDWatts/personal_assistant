"""One maintained plan per commitment, with evidence and revision history."""
from engine.tools import ToolError, _day


class Plans:
    def __init__(self, tools):
        self.tools, self.map = tools, tools.map

    async def add(self, args):
        day = _day(args.get('day'), today=self.tools.event_time().date())
        item = ' '.join(args['item'].split())
        if not item: raise ToolError('A plan needs a description.')
        if args.get('status')=='done' and day>self.tools.event_time().date(): raise ToolError('A future occurrence cannot be completed already. Use the actual occurrence date.')
        with self.map.conn.transaction():
            # Both the conversational agent and extractor can see the same task.
            # Serialize exact matches; semantic matches require an explicit merge.
            self.map.execute('select pg_advisory_xact_lock(hashtextextended(%s,0))', (f'plan:{day}:{item.lower()}',))
            existing = self.map.row("select * from memory.plans where day=%s and lower(regexp_replace(btrim(item),'\\s+',' ','g'))=%s and superseded_by is null order by id limit 1", (day,item.lower()))
            if existing:
                if args.get('status') == 'done' and existing['status'] != 'done':
                    raise ToolError(f"Plan {existing['id']} already exists at version {existing['version']}. Use plan_update to record its outcome.")
                return existing  # Never resurrect it from a duplicate add.
            obs = self.tools.observe('plan', args.get('statement') or item)
            return self.map.row('insert into memory.plans(day,item,category,entity_id,status,origin,rationale,source_observation_id,created_by) values(%s,%s,%s,%s,%s,%s,%s,%s,%s) returning *',
                (day,item,args.get('category'),args.get('entity_id'),args.get('status') or ('proposed' if args.get('origin') in ('map','agent') else 'planned'),args.get('origin') or 'user',args.get('rationale'),obs,self.tools.device))

    async def update(self, args):
        with self.map.conn.transaction():
            row = self.map.row('select * from memory.plans where id=%s for update',(args['plan_id'],))
            if not row: raise ToolError(f"no plan {args['plan_id']}")
            if row['superseded_by']: raise ToolError(f"Use canonical plan {row['superseded_by']} instead.")
            if row['version'] != args['version']: raise ToolError('The plan changed. Read it again before updating.')
            evidence_at = self.map.value('select occurred_at from memory.observations where id=%s', (row['last_observation_id'] or row['source_observation_id'],))
            if evidence_at and self.tools.event_time() < evidence_at:
                raise ToolError('Newer evidence already updated this plan. Do not overwrite it with this earlier message.')
            day = _day(args['day'],today=self.tools.event_time().date()) if args.get('day') else row['day']
            if args.get('status',row['status'])=='done' and day>self.tools.event_time().date():
                raise ToolError('A future occurrence cannot be completed already. Correct its date or status.')
            obs = self.tools.observe('outcome', args['note'])
            status = args.get('status', row['status'])
            result = self.map.row('update memory.plans set status=%s,item=%s,day=%s,outcome_note=%s,resolved_at=%s,last_observation_id=%s where id=%s returning *',
                (status,args.get('item',row['item']),day,args['note'],
                 self.tools.event_time() if status in ('done','skipped','dropped') else None,obs,row['id']))
            if status in ('done','skipped','dropped'):
                self.map.execute("update memory.questions set closed_at=now(),closed_reason='Plan updated with evidence',answer=%s where ref_table='plans' and ref_id=%s and closed_at is null", (args['note'],str(row['id'])))
            return result

    async def merge(self, args):
        if args['plan_id'] == args['into_id']: raise ToolError('Choose two distinct plans.')
        with self.map.conn.transaction():
            rows = self.map.rows('select * from memory.plans where id=any(%s) order by id for update',([args['plan_id'],args['into_id']],))
            by_id = {r['id']:r for r in rows}
            if len(rows)!=2: raise ToolError('Read both plans before merging.')
            old, target = by_id[args['plan_id']], by_id[args['into_id']]
            if old['version']!=args['version'] or target['version']!=args['into_version'] or old['superseded_by'] or target['superseded_by']:
                raise ToolError('A plan changed. Read both again before merging.')
            if old['day']!=target['day']: raise ToolError('Different days may be distinct occurrences. Correct dates explicitly before merging.')
            obs = self.tools.observe('outcome',args['note'])
            self.map.execute('update memory.plans set superseded_by=%s,last_observation_id=%s where id=%s',(target['id'],obs,old['id']))
            self.map.execute("update memory.questions set ref_id=%s where ref_table='plans' and ref_id=%s and closed_at is null",(str(target['id']),str(old['id'])))
            return {'merged':old['id'],'into':target['id'],'status':target['status']}
