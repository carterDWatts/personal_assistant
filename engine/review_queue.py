"""Attention decisions are separate from factual outcomes, with a durable revisit date."""
from datetime import timedelta
from engine.tools import ToolError


def candidates(map_, limit=8, *, maintenance=False):
    # A page is a context budget, not a cap on questions or on retained commitments.
    return map_.rows("select * from memory.review_candidates where action is distinct from 'dismiss'"
        + (" and (review_after is null or review_after<=current_date)" if maintenance else
           " and (action is distinct from 'defer' or review_after<=current_date)")
        + (" order by reviewed_at nulls first,priority desc" if maintenance else " order by priority desc,reviewed_at nulls first")
        + ",day,kind,ref_id limit %s", (limit,))


def decide(tools, args):
    kind, ref = args['kind'], str(args['ref_id'])
    with tools.map.conn.transaction():
        # Serialize attention changes with writes to their actual subject.
        table = {'question':'questions','plan':'plans'}[kind]
        tools.map.execute(f'select id from memory.{table} where id::text=%s for update', (ref,))
        item = tools.map.row('select * from memory.review_candidates where kind=%s and ref_id=%s', (kind,ref))
        if not item or item['revision'] != args['revision']:
            raise ToolError('This item changed or was resolved. Read the review queue again.')
        reason = args['reason'].strip()
        if not reason: raise ToolError('Explain what decision this review affects, or why it can wait.')
        action = args['action']
        user = tools.map.value("select role='user' and not coalesce((payload->>'external')::boolean,false) from memory.messages where id=%s", (tools.message_id,)) if tools.message_id else False
        if action == 'dismiss' and not user:
            raise ToolError('Dismissing a review requires the user’s direction. Defer uncertain relevance with a revisit date instead.')
        days = max(1,min(int(args.get('days',1)),30 if user else 7))
        if item['priority'] >= 3 and not user: days = 1
        tools.map.execute('insert into memory.review_decisions(kind,ref_id,revision,action,reason,review_after,message_id) values(%s,%s,%s,%s,%s,%s,%s)',
            (kind,ref,item['revision'],action,reason,tools.map.value('select current_date')+timedelta(days=days),tools.message_id))
        return {'saved':True,'outcome_changed':False}


def schema():
    from engine.tools import _obj,_s,_i
    return _obj({'kind':_s('review subject',enum=['question','plan']), 'ref_id':_s('ID from the queue'),
        'revision':_s('Revision from the queue'), 'action':_s('keep for discussion, defer until later, or dismiss at the user’s direction',enum=['keep','defer','dismiss']),
        'reason':_s('Concrete consequence of the uncertainty or reason it no longer needs attention',minLength=1),
        'days':_i('Revisit in this many days; deferral never completes a task',minimum=1,maximum=30)},
        ['kind','ref_id','revision','action','reason'])
