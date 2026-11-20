"""Collect bounded trip evidence without inventing bookings or duplicating calendars."""
from datetime import datetime
from urllib.parse import quote
from engine.integrations import google
from engine.integrations.results import tool,snapshot
from engine.tools import ToolError


def sources(args):
    start=datetime.fromisoformat(args['start'].replace('Z','+00:00'));end=datetime.fromisoformat(args['end'].replace('Z','+00:00'))
    if not start.tzinfo or not end.tzinfo or not 0<(end-start).total_seconds()<=31*86400:
        raise ToolError('Choose a trip window of at most 31 days, with explicit time zones.')
    calendars=google._get('calendar/v3/users/me/calendarList').get('items',[])
    events=[];truncated=False
    for calendar in [c for c in calendars if c.get('selected') or c.get('primary')][:10]:
        data=google._get('calendar/v3/calendars/'+quote(calendar['id'],safe='')+'/events',{'timeMin':start.isoformat(),'timeMax':end.isoformat(),'singleEvents':'true','orderBy':'startTime','maxResults':50})
        events.extend({'calendar_id':calendar['id'],**{k:event[k] for k in ('id','summary','start','end','location','htmlLink','status') if k in event}} for event in data.get('items',[]))
        truncated=truncated or bool(data.get('nextPageToken'))
    mail=google._mail({'query':args.get('mail_query','newer_than:180d {reservation itinerary "booking confirmation" "flight confirmation" "hotel confirmation"}')})
    return snapshot(calendar_events=events,calendar_truncated=truncated,mail=mail,
        caution='Email matches are excerpts, not confirmed trip membership. Read relevant messages in full, check dates and cancellation/change notices, and link verified facts to their evidence. This does not check live flight status or make bookings.')


def specs():
    return [tool('travel_sources','Gather calendar entries for a trip window and booking email excerpts. Use before building an itinerary; read matching emails fully. Keeps the connected calendar authoritative. Does not book or confirm live flight status.',sources,
        {'start':{'type':'string','format':'date-time'},'end':{'type':'string','format':'date-time'},'mail_query':{'type':'string','maxLength':500}},['start','end'])]
