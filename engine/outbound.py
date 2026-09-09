"""Store unsolicited messages in the inbox until the user opens a discussion."""
import json
from engine.db import jsonb, dumps


def post(map_, key, text, reference=None):
    with map_.conn.transaction():
        owner = map_.value('select user_id from assistant.owner for update')
        map_.execute("select pg_advisory_xact_lock(hashtextextended('assistant-outbound',0))")
        existing = map_.value('select message_id from assistant.outbound where key=%s', (key,))
        if existing: return existing
        segment = map_.value("select id from memory.conversations where agent='outbound' order by started_at desc limit 1")
        if not segment:
            segment = map_.value("insert into memory.conversations(agent,device,runtime) values('outbound','cloud','background') returning id")
        payload = {'proactive': True, 'reference': reference}
        row = map_.row("insert into memory.messages(conversation_id,seq,role,content,payload) values(%s,"
                      "(select coalesce(max(seq),0)+1 from memory.messages where conversation_id=%s),'assistant',%s,%s)"
                      " returning id,role,content,created_at,payload", (segment, segment, text, jsonb(payload)))
        map_.execute('insert into assistant.outbound(key,message_id,reference) values(%s,%s,%s)',
                     (key, row['id'], jsonb(reference)))
        if owner:
            map_.value('select assistant.emit(%s,null,%s)', (owner, jsonb(json.loads(dumps({'type':'inbox_received', 'message':row})))))
        return row['id']
