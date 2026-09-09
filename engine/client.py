"""Trusted native-client requests. None of these operations are model tools."""
import uuid
from engine import config
from engine.db import jsonb
from engine.tools import ToolError


def inbox_request(map_,action,args):
    if action not in ("inbox","inbox_open","inbox_cancel"): raise ToolError("Invalid inbox operation.")
    owner=map_.value("select user_id from assistant.owner")
    device=uuid.uuid5(uuid.NAMESPACE_URL,"personal-assistant:desktop:"+config.DEVICE)
    map_.value("select public.assistant_client(%s,%s,%s,%s)",(owner,device,"register",jsonb({"name":config.DEVICE})))
    return map_.value("select public.assistant_client(%s,%s,%s,%s)",(owner,device,action,jsonb(args)))


def email_request(map_,args):
    if args.get('operation') not in ('list','get','approve','discard'): raise ToolError('Invalid email operation.')
    owner=map_.value('select user_id from assistant.owner')
    if not owner: raise ToolError('This installation has no signed-in owner.')
    device=uuid.uuid5(uuid.NAMESPACE_URL,'personal-assistant:desktop:'+config.DEVICE)
    map_.value('select public.assistant_client(%s,%s,%s,%s)',(owner,device,'register',jsonb({'name':config.DEVICE})))
    return map_.value('select public.assistant_email(%s,%s,%s,%s)',(owner,device,args['operation'],jsonb(args)))
