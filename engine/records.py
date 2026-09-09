"""Dated quantities and events, with explicit outcomes and source-backed corrections."""
from datetime import date
from engine.db import jsonb
from engine.tools import ToolError, ToolSpec, _obj, _s, _i

QUANTITY = _obj({'value': {'type':'number'}, 'unit': _s('Canonical unit, such as kcal, g, lb, h or USD', minLength=1, maxLength=40),
                 'basis': _s('measured, label or estimate', enum=['measured','label','estimate'])}, ['value','unit','basis'])


class Records:
    def __init__(self, tools): self.tools=tools; self.map=tools.map

    async def save(self,args):
        message=self.map.row('select role,payload,created_at from memory.messages where id=%s',(self.tools.message_id,))
        if not message or (message['payload'] or {}).get('external') or message['role'] not in ('user','system'):
            raise ToolError('A record requires user-provided evidence, not an assistant suggestion.')
        if message['role']=='system' and not (message['payload'] or {}).get('import_id'):
            raise ToolError('A record requires a user message or an imported source.')
        day=date.fromisoformat(args['day'])
        source_day=message['created_at'].date()
        if args['status']=='actual' and day>source_day: raise ToolError('An event that has not happened yet must remain planned.')
        with self.map.conn.transaction():
            self.map.execute("select pg_advisory_xact_lock(hashtextextended('memory-records',0))")
            row=self.map.row('select * from memory.records where id=%s for update',(args['id'],)) if args.get('id') else self.map.row(
                'select * from memory.records where kind=%s and day=%s and slot=%s for update',(args['kind'],day,args['slot']))
            if row and row['message_id']>self.tools.message_id:
                return {'saved':False,'superseded':True,'id':str(row['id']),'current':row}
            if row and row['message_id']==self.tools.message_id:
                identical=all(row[k]==args.get(k,{} if k=='details' else None) for k in ('kind','slot','status','quantities','details')) and row['day']==day
                if identical or self.tools.device=='memory-worker':
                    return {'saved':identical,'already_recorded':True,'id':str(row['id']),'version':row['version'],'current':row}
            if args.get('id') and not row: raise ToolError('No such record. Read the records before correcting one.')
            values=(args.get('entity_id'),args['kind'],day,args['slot'],args['status'],jsonb(args['quantities']),jsonb(args.get('details',{})),self.tools.message_id)
            if row:
                if args.get('id')!=str(row['id']) or args.get('expected_version')!=row['version']:
                    raise ToolError(f"Record already exists: {row['id']} version {row['version']}. Read it and supply its id and expected_version to correct it.")
                result=self.map.row('update memory.records set entity_id=%s,kind=%s,day=%s,slot=%s,status=%s,quantities=%s,details=%s,message_id=%s where id=%s returning id,version',(*values,row['id']))
            else:
                result=self.map.row('insert into memory.records(entity_id,kind,day,slot,status,quantities,details,message_id) values(%s,%s,%s,%s,%s,%s,%s,%s) returning id,version',values)
            return {'saved':True,**result}

    def bounds(self,args):
        start,end=date.fromisoformat(args['from_day']),date.fromisoformat(args['to_day'])
        if not 0<=(end-start).days<=366: raise ToolError('Use a date range of at most one year, oldest first.')
        return start,end

    async def read(self,args):
        start,end=self.bounds(args)
        offset=args.get('offset',0)
        rows=self.map.rows('select * from memory.records where day between %s and %s and (%s::text is null or kind=%s)'
            " and (%s='all' or status=%s) order by day,slot,id limit 101 offset %s",
            (start,end,args.get('kind'),args.get('kind'),args.get('status','actual'),args.get('status','actual'),offset))
        return {'records':rows[:100],'next_offset':offset+100 if len(rows)>100 else None,
                'coverage':'Only recorded entries. Missing days or quantities are unknown, not zero.'}

    async def totals(self,args):
        start,end=self.bounds(args)
        aggregate=args.get('aggregate','sum')
        if aggregate not in ('sum','avg','min','max'): raise ToolError('Unsupported aggregation.')
        rows=self.map.rows(f"select day,q.key metric,q.value->>'unit' unit,{aggregate}((q.value->>'value')::numeric) value,"
            " count(*) entries,count(*) filter(where q.value->>'basis'='estimate') estimates,array_agg(r.id) record_ids"
            " from memory.records r cross join lateral jsonb_each(r.quantities) q where status='actual'"
            " and kind=%s and day between %s and %s group by day,q.key,q.value->>'unit' order by day,q.key,unit",
            (args['kind'],start,end))
        return {'days':rows,'aggregate':aggregate,'coverage':'Only actual recorded entries; no planned/retracted entries. Missing days and metrics are unknown. Different units remain separate.'}

    def specs(self):
        dates={'from_day':_s('Inclusive YYYY-MM-DD'), 'to_day':_s('Inclusive YYYY-MM-DD')}
        return [
            ToolSpec('record_save','Save a dated observation or planned event immediately: meals, measurements, workouts, expenses or other tracked activity. Save numeric values with units; mark model-derived numbers as estimates. Record individual entries, not duplicate running totals. status actual requires evidence it happened; intentions are planned. Use a stable kind and slot (e.g. meal/breakfast, weight/morning), and reuse the existing metric names/units. details preserves ingredients, portions, assumptions and links. Corrections replace the full record with id+expected_version; retract a record that was never true. The background worker deduplicates the same source.',
                _obj({'id':_s('Record UUID for correction'), 'expected_version':_i('Version read before correcting'), 'entity_id':_s('Related entity UUID, if known'),
                    'kind':_s('Stable category',minLength=1,maxLength=80),'day':_s('Date of the event, YYYY-MM-DD, not the processing date'),
                    'slot':_s('Stable identifying label within that kind and day',minLength=1,maxLength=160),
                    'status':_s('actual, planned or retracted',enum=['actual','planned','retracted']),
                    'quantities':{'type':'object','maxProperties':30,'additionalProperties':QUANTITY},
                    'details':{'type':'object'}},['kind','day','slot','status','quantities']),self.save),
            ToolSpec('records_read','Read dated observations and events across days or months, including exact numeric quantities and source message IDs. Use status all to find a planned entry before confirming/correcting it. Follow next_offset until null. Use the transcript to recover missing older entries.',
                _obj({**dates,'kind':_s('Optional category'),'status':_s('actual, planned, retracted or all',enum=['actual','planned','retracted','all']),
                      'offset':_i('Pagination offset',minimum=0)},list(dates)),self.read),
            ToolSpec('records_totals','Calculate daily quantities from actual recorded entries in SQL. Use sum for intake/spending, avg for repeated measurements. No missing day is treated as zero. Estimate counts and source record IDs accompany results. Reuse canonical units; separate units are never silently combined.',
                _obj({**dates,'kind':_s('Category to aggregate'),'aggregate':_s('sum, avg, min or max',enum=['sum','avg','min','max'])},[*dates,'kind']),self.totals)]
