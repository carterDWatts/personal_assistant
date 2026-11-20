"""Attach a native location trigger to an existing contextual reminder."""
from uuid import uuid4
from engine.db import jsonb
from engine.tools import ToolError,ToolSpec,_obj

class LocationReminders:
    def __init__(self,tools,command):self.map=tools.map;self.command=command
    async def configure(self,args):
        if self.command is None:raise ToolError('Open this conversation on your iPhone to configure a location reminder.')
        # The phone confirms its own permission and notification scheduling before
        # replacing the ordinary follow-up. A failed setup leaves the reminder intact.
        row=self.map.row("select * from memory.reminders where id=%s and version=%s and status='open'",(args['id'],args['version']))
        if not row:raise ToolError('Read the current open reminder before adding its location trigger.')
        if row['alarm_at']:raise ToolError('This reminder has a timed alarm. Keep that alarm or remove it before adding a location trigger.')
        result=await self.command({'action':'location_reminder','id':str(row['id']),'version':row['version']+1,
             'title':row['title'],**{k:args[k] for k in ('latitude','longitude','radius','event')}})
        if not result.get('scheduled'):return result
        with self.map.conn.transaction():
            self.map.execute('select user_id from assistant.owner for update')
            current=self.map.row("select * from memory.reminders where id=%s for update",(row['id'],))
            if current['version']!=row['version'] or current['status']!='open':
                raise ToolError('The reminder changed while the phone scheduled it. The next sync will remove the outdated notification.')
            # Location is a delivery condition, not evidence of completion.
            geo={k:args[k] for k in ('latitude','longitude','radius','event')}
            geo['device_id']=result['device_id']
            geo['configuration_id']=str(uuid4())
            self.map.execute("update memory.reminders set location_trigger=%s,version=version+1 where id=%s",(jsonb(geo),row['id']))
            self.map.execute('update assistant.reminder_deliveries set cancelled_at=now() where reminder_id=%s and sent_at is null and cancelled_at is null',(row['id'],))
        return {'id':row['id'],'scheduled':True,'note':'One location notification on this phone. Completion is still tracked separately; changes sync when the app connects.'}
    def specs(self):
        return [ToolSpec('reminder_at_location','Attach an arrival or departure notification to an existing open reminder. First save the commitment normally, then supply its current id/version and a resolved place. Requires phone Location Always and notification permission. Radius is meters (100–5000). A location trigger never marks a task done. Only claim scheduled after a phone receipt.',
            _obj({'id':{'type':'string','format':'uuid'},'version':{'type':'integer','minimum':1},'latitude':{'type':'number','minimum':-90,'maximum':90},'longitude':{'type':'number','minimum':-180,'maximum':180},'radius':{'type':'number','minimum':100,'maximum':5000},'event':{'enum':['arrival','departure']}},['id','version','latitude','longitude','radius','event']),self.configure)]
