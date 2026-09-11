"""Contextual commitments with explicit completion and durable follow-up timing."""
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo
import uuid
from engine import config
from engine.db import jsonb, dumps
from engine.tools import ToolError


def next_time(timing, start, hours, zone, now=None):
    now = (now or datetime.now().astimezone()).astimezone(ZoneInfo(zone))
    candidate = max(start.astimezone(ZoneInfo(zone)), now + timedelta(hours=hours))
    if timing != 'exact':
        candidate = candidate.replace(hour=12, minute=0, second=0, microsecond=0)
        if candidate <= now or candidate < start:
            candidate += timedelta(days=1)
    return candidate


class Reminders:
    def __init__(self, tools): self.tools = tools; self.map = tools.map

    async def list(self, args):
        table='reminders' if args.get('include_inactive') or args.get('status','open')!='open' else 'active_reminders'
        rows = self.map.rows(f"select * from memory.{table} where status=%s and (%s='' or title ilike %s or context ilike %s) order by next_notify_at limit 100",
            (args.get('status','open'), args.get('query',''), '%'+args.get('query','')+'%', '%'+args.get('query','')+'%'))
        return [self.delivery(r) for r in rows]

    def delivery(self, row):
        if row.get('alarm_at'):
            row['alarm_delivery'] = self.map.rows("select a.status,a.version,a.updated_at from assistant.alarm_receipts a join assistant.devices d on d.id=a.device_id where a.reminder_id=%s and a.version=%s and d.revoked_at is null",(row['id'],row['version']))
            row['alarm_ready'] = any(r['status']=='scheduled' for r in row['alarm_delivery'])
            if row['status']!='open':
                row['alarm_note'] = 'Reminder closed. The phone must sync to cancel any previously scheduled native alarm; current device receipts describe that confirmation.'
                return row
            row['alarm_note'] = 'Native alarm confirmed on a phone.' if row['alarm_ready'] else 'Not confirmed on a phone. Open the updated iPhone app and allow Alarms; ordinary notifications are not a ringing alarm.'
        return row

    async def save(self, args):
        zone = args.get('timezone', config.TIMEZONE)
        ZoneInfo(zone)
        start = datetime.fromisoformat(args['window_start'])
        end = datetime.fromisoformat(args['window_end']) if args.get('window_end') else None
        if not start.tzinfo or (end and not end.tzinfo): raise ValueError('Use timestamps with UTC offsets.')
        if args.get('alarm') and (args['timing']!='exact' or start<=datetime.now().astimezone()):
            raise ValueError('An alarm needs an exact future time, with a UTC offset.')
        kind = args.get('kind', 'task')
        if kind == 'check_in' and end is None:
            raise ValueError('Check-ins require a delivery window end.')
        hours = args.get('followup_hours', {'exact':1,'day':24,'week':72,'someday':168}[args['timing']])
        first = next_time(args['timing'], start, 168 if args['timing']=='someday' else 0, zone)
        identifier = args.get('id') or str(uuid.uuid5(uuid.NAMESPACE_URL, f"reminder:{self.tools.message_id}:{args['title']}"))
        with self.map.conn.transaction():
            self.map.execute("select pg_advisory_xact_lock(hashtextextended('reminder-save',0))")
            if args.get('id'):
                result = self.map.row("update memory.reminders set title=%s,context=%s,timing=%s,window_start=%s,window_end=%s,next_notify_at=%s,followup_hours=%s,timezone=%s,severity=%s,kind=%s,alarm_at=case when coalesce(%s,alarm_at is not null) then %s else null end,version=version+1,updated_at=now() where id=%s and version=%s and status='open' returning *",
                    (args['title'],args['context'],args['timing'],start,end,first,hours,zone,args.get('severity','normal'),kind,args.get('alarm'),start,identifier,args.get('version')))
                if not result: raise ValueError('Reminder changed. Read it again before editing.')
                return self.delivery(result)
            replay=self.map.row('select * from memory.reminders where id=%s',(identifier,))
            if replay:return self.delivery(replay)
            candidates=self.map.rows("""select id,title,version,context,window_start,window_end,alarm_at from memory.reminders
                where status='open' and kind=%s and
                (source_message_id=%s or tstzrange(window_start,window_end,'[]') && tstzrange(%s,%s,'[]'))
                and (extensions.similarity(lower(title),lower(%s))>=0.45 or lower(title)=lower(%s))
                order by updated_at desc limit 8""",(kind,self.tools.message_id,start,end,args['title'],args['title']))
            unresolved=[r for r in candidates if str(r['id']) not in args.get('distinct_from',[])]
            if unresolved:
                raise ToolError('Possible existing reminder. Update its id/version, or pass distinct_from IDs only if these are separate occurrences/tasks. Do not duplicate it. Candidates: '+dumps(unresolved))
            self.map.execute("insert into memory.reminders(id,title,context,timing,window_start,window_end,next_notify_at,followup_hours,timezone,source_message_id,severity,kind,alarm_at) values(%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s) on conflict(id) do nothing",
                (identifier,args['title'],args['context'],args['timing'],start,end,first,hours,zone,self.tools.message_id,args.get('severity','normal'),kind,start if args.get('alarm') else None))
            return self.delivery(self.map.row('select * from memory.reminders where id=%s',(identifier,)))

    async def merge(self,args):
        if args['id']==args['into']:raise ToolError('Choose two different reminders.')
        with self.map.conn.transaction():
            self.map.execute("select pg_advisory_xact_lock(hashtextextended('reminder-save',0))")
            rows=self.map.rows('select * from memory.reminders where id=any(%s::uuid[]) order by id for update',([args['id'],args['into']],))
            source=next((r for r in rows if str(r['id'])==args['id']),None)
            target=next((r for r in rows if str(r['id'])==args['into']),None)
            if not source or not target:raise ToolError('Read both reminders first.')
            if str(source.get('merged_into'))==args['into']:return self.delivery(target)
            if source['status']!='open' or target['status']!='open' or source['version']!=args['version'] or target['version']!=args['into_version']:
                raise ToolError('Reminder changed. Read both again before merging.')
            if source['kind']!=target['kind'] or source['alarm_at']!=target['alarm_at']:
                raise ToolError('Different reminder kinds or alarms need explicit reconciliation before merging.')
            from engine.plans import merge_questions
            merge_questions(self.map,'reminders',args['id'],args['into'])
            self.map.value('select memory.reminder_action(%s)',(jsonb({'id':args['id'],'version':args['version'],'action':'cancel','message_id':self.tools.message_id}),))
            self.map.execute('update memory.reminders set merged_into=%s,merge_reason=%s where id=%s',(args['into'],args['reason'],args['id']))
            result=self.map.row('update memory.reminders set context=%s,version=version+1,updated_at=now() where id=%s returning *',(args['context'],args['into']))
            return self.delivery(result)

    async def act(self, args):
        return self.delivery(self.map.value('select memory.reminder_action(%s)', (jsonb({**args,'message_id':self.tools.message_id}),)))

    def specs(self):
        from engine.tools import ToolSpec
        string={'type':'string'}
        return [ToolSpec('reminders_list','Read reminders, including their context and timing. Search relevant long-term tasks during conversation; check due reminders each morning.',
            {'type':'object','properties':{'query':string,'include_inactive':{'type':'boolean','description':'Include expired/delivered check-ins for history or cleanup.'},'status':{'type':'string','enum':['open','completed','cancelled']}},'additionalProperties':False},self.list),
            ToolSpec('reminder_save','Save or edit a reminder. Reuse existing id/version when discussing the same commitment. Possible duplicates are rejected until resolved; distinct_from is only for genuinely separate tasks or occurrences. Choose kind=task for unfinished work that must remain tracked after its deadline. Choose kind=check_in for a scheduled briefing or nudge: one occurrence, delivered at most once within window_start/window_end, with no hourly follow-ups. Each later occurrence needs its own explicit window; followup_hours is not a recurrence rule. Use alarm=true only when the user asks for a ringing alarm, at an exact future time. Alarm readiness requires a scheduled phone receipt; if alarm_ready is false, explain it is waiting for the iPhone app and Alarms permission, not a verified alarm. Severity alone never enables ringing. alarm=false removes ringing. Do this immediately, before claiming it is saved. Distinct from a calendar event. Interpret tomorrow/this week using local time. Preserve why it matters and dependencies in context. Use a day/week window rather than inventing a deadline. Someday gets a later first window and gentle follow-up. Severity measures consequences of missing it, separate from when it is due. Default normal; critical requires concrete serious consequences, not just an emphatic phrase. Choose followup_hours proportionate to consequences and urgency; do not nag. Editing requires id and version from reminders_list. Do not create reminders from quoted imports without the user adopting them.',
            {'type':'object','properties':{'distinct_from':{'type':'array','maxItems':8,'items':string},'alarm':{'type':'boolean'},'kind':{'type':'string','enum':['task','check_in']},'id':string,'version':{'type':'integer'},'title':{'type':'string','minLength':1,'maxLength':300},'context':{'type':'string','maxLength':5000},'timing':{'type':'string','enum':['exact','day','week','someday']},'window_start':string,'window_end':string,'timezone':string,'severity':{'type':'string','enum':['low','normal','high','critical']},'followup_hours':{'type':'number','minimum':0.25,'maximum':168}},'required':['kind','title','context','timing','window_start'],'additionalProperties':False},self.save),
            ToolSpec('reminder_merge','Merge two records only when they track the same commitment or occurrence. Keep the canonical timing and title, provide the combined current context, and preserve the other record as linked history. Never merge separate daily occurrences or assume completion.',
                {'type':'object','properties':{'id':string,'version':{'type':'integer'},'into':string,'into_version':{'type':'integer'},'context':{'type':'string','maxLength':5000},'reason':{'type':'string','minLength':1,'maxLength':1000}},'required':['id','version','into','into_version','context','reason'],'additionalProperties':False},self.merge),
            ToolSpec('reminder_action','Mark done only when the user confirms completion; opening or dismissing a notification is not completion. Snooze to a future timestamp, or cancel on request. Read current id/version first.',
            {'type':'object','properties':{'id':string,'version':{'type':'integer'},'action':{'type':'string','enum':['done','snooze','cancel']},'until':string},'required':['id','version','action'],'additionalProperties':False},self.act)]
