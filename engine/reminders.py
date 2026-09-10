"""Contextual commitments with explicit completion and durable follow-up timing."""
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo
import uuid
from engine import config
from engine.db import jsonb


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
        rows = self.map.rows("select * from memory.reminders where status=%s and (%s='' or title ilike %s or context ilike %s) order by next_notify_at limit 100",
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
            if args.get('id'):
                result = self.map.row("update memory.reminders set title=%s,context=%s,timing=%s,window_start=%s,window_end=%s,next_notify_at=%s,followup_hours=%s,timezone=%s,severity=%s,kind=%s,alarm_at=case when coalesce(%s,alarm_at is not null) then %s else null end,version=version+1,updated_at=now() where id=%s and version=%s and status='open' returning *",
                    (args['title'],args['context'],args['timing'],start,end,first,hours,zone,args.get('severity','normal'),kind,args.get('alarm'),start,identifier,args.get('version')))
                if not result: raise ValueError('Reminder changed. Read it again before editing.')
                return self.delivery(result)
            self.map.execute("insert into memory.reminders(id,title,context,timing,window_start,window_end,next_notify_at,followup_hours,timezone,source_message_id,severity,kind,alarm_at) values(%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s) on conflict(id) do nothing",
                (identifier,args['title'],args['context'],args['timing'],start,end,first,hours,zone,self.tools.message_id,args.get('severity','normal'),kind,start if args.get('alarm') else None))
            return self.delivery(self.map.row('select * from memory.reminders where id=%s',(identifier,)))

    async def act(self, args):
        return self.delivery(self.map.value('select memory.reminder_action(%s)', (jsonb({**args,'message_id':self.tools.message_id}),)))

    def specs(self):
        from engine.tools import ToolSpec
        string={'type':'string'}
        return [ToolSpec('reminders_list','Read reminders, including their context and timing. Search relevant long-term tasks during conversation; check due reminders each morning.',
            {'type':'object','properties':{'query':string,'status':{'type':'string','enum':['open','completed','cancelled']}},'additionalProperties':False},self.list),
            ToolSpec('reminder_save','Save or edit a reminder. Choose kind=task for unfinished work that must remain tracked after its deadline. Choose kind=check_in for a scheduled briefing or nudge: one occurrence, delivered at most once within window_start/window_end, with no hourly follow-ups. Each later occurrence needs its own explicit window; followup_hours is not a recurrence rule. Use alarm=true only when the user asks for a ringing alarm, at an exact future time. Alarm readiness requires a scheduled phone receipt; if alarm_ready is false, explain it is waiting for the iPhone app and Alarms permission, not a verified alarm. Severity alone never enables ringing. alarm=false removes ringing. Do this immediately, before claiming it is saved. Distinct from a calendar event. Interpret tomorrow/this week using local time. Preserve why it matters and dependencies in context. Use a day/week window rather than inventing a deadline. Someday gets a later first window and gentle follow-up. Severity measures consequences of missing it, separate from when it is due. Default normal; critical requires concrete serious consequences, not just an emphatic phrase. Choose followup_hours proportionate to consequences and urgency; do not nag. Editing requires id and version from reminders_list. Do not create reminders from quoted imports without the user adopting them.',
            {'type':'object','properties':{'alarm':{'type':'boolean'},'kind':{'type':'string','enum':['task','check_in']},'id':string,'version':{'type':'integer'},'title':{'type':'string','minLength':1,'maxLength':300},'context':{'type':'string','maxLength':5000},'timing':{'type':'string','enum':['exact','day','week','someday']},'window_start':string,'window_end':string,'timezone':string,'severity':{'type':'string','enum':['low','normal','high','critical']},'followup_hours':{'type':'number','minimum':0.25,'maximum':168}},'required':['kind','title','context','timing','window_start'],'additionalProperties':False},self.save),
            ToolSpec('reminder_action','Mark done only when the user confirms completion; opening or dismissing a notification is not completion. Snooze to a future timestamp, or cancel on request. Read current id/version first.',
            {'type':'object','properties':{'id':string,'version':{'type':'integer'},'action':{'type':'string','enum':['done','snooze','cancel']},'until':string},'required':['id','version','action'],'additionalProperties':False},self.act)]
