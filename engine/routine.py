"""Progress belongs to a morning conversation, not a model's recollection of it."""
from engine.db import jsonb
from engine.tools import ToolError, ToolSpec, _obj, _s, _i
from engine import review_queue
import re


def requested(text):
    """Recognize explicit routine commands, not mentions of a future morning."""
    text = ' '.join(re.sub(r"[^a-z ]", '', text.lower().replace('’', "'")).split())
    text = re.sub(r'^(?:ok(?:ay)?|yes|yeah|please)[ ]+', '', text)
    return 'morning' if re.fullmatch(r"(?:(?:lets|i will|can we|can you|please) )?(?:start|begin|open)(?: the| my| our)? morning(?: routine| review| session)?(?: please)?",text) else None


def active(map_):
    """The morning belongs to the day, even if its first reply was interrupted."""
    return map_.value("select c.id from memory.conversations c where c.agent in ('morning','review')"
        " and c.started_at::date=current_date and c.started_at >= coalesce("
        "(select created_at from memory.messages where role='system' and payload->>'event'='chat_cleared'"
        " order by id desc limit 1), '-infinity'::timestamptz) order by c.started_at desc limit 1")


def progress(map_, conversation):
    row=map_.row('select steps,position,rule_ids,ended_at,review_focus from memory.routine_progress where conversation_id=%s',(conversation,))
    queue = review_queue.candidates(map_)
    if not row: return {'state':'not_started','review_queue':queue,'instruction':'Set the agenda from saved preferences. Lead it and work through consequential uncertainties; do not wait for the user to name each topic.'}
    if row['ended_at']: return {**row,'state':'complete','current':None,'completed':row['steps'][:row['position']]}
    focus = row['review_focus']
    if focus and not map_.value('select exists(select 1 from memory.review_candidates where kind=%s and ref_id=%s and revision=%s and action is distinct from \'dismiss\' and (action is distinct from \'defer\' or review_after<=current_date))',(focus['kind'],focus['ref_id'],focus['revision'])):
        focus = None
    result = {**row,'review_focus':focus,'review_queue':queue,'state':'active' if row['position']<len(row['steps']) else ('review' if queue or focus else 'complete'),
            'current':row['steps'][row['position']] if row['position']<len(row['steps']) else None,
            'completed':row['steps'][:row['position']]}
    result['next_action'] = ('Resolve the focused answer with memory_clarify/plan_update, or explicitly defer it. Do not repeat a confirmation.' if focus else
        'Give the current section, then lead into the next useful decision. Acknowledgments advance it.' if result['current'] else
        'Review the queue: inspect evidence, ask one consequential uncertainty, or defer with a reason and revisit date. End when the user is done.' if queue else 'The routine is complete.')
    return result


async def steer(tools, conversation, text):
    # Explicit navigation is applied before inference. Other replies need interpretation.
    command = re.sub(r"[^a-z ]", '', text.lower().replace('’', "'"))
    command = ' '.join(command.split())
    state = progress(tools.map, conversation)
    if command in {'stop the morning', 'end the morning', 'thats all for now', 'stop the review'}:
        tools.map.execute('update memory.routine_progress set ended_at=clock_timestamp() where conversation_id=%s',(conversation,))
        return
    navigation = command in {'move on', 'lets move on', 'please move on', 'next', 'next section', 'skip this section'}
    acknowledged = command in {'yes','yep','yeah','correct','right','ok','okay','ok cool','okay cool','sounds good'}
    last = tools.map.value("select content from memory.messages where conversation_id=%s and role='assistant' order by id desc limit 1",(conversation,)) or ''
    if navigation or acknowledged and not state.get('review_focus') and '?' not in last:
        if navigation and state.get('review_focus'):
            focus = state['review_focus']
            review_queue.decide(tools,{**focus,'action':'defer','reason':'User moved on; outcome remains unknown.','days':1})
        current = state.get('current')
        if current:
            await spec(tools, conversation).fn({'completed_step': current})


def spec(tools,conversation):
    async def update(args):
        with tools.map.conn.transaction():
            tools.map.execute('select id from memory.conversations where id=%s for update',(conversation,))
            row=tools.map.row('select * from memory.routine_progress where conversation_id=%s for update',(conversation,))
            if args.get('review'):
                if not row: raise ToolError('Set the agenda first.')
                review_queue.decide(tools,args['review'])
            elif args.get('focus'):
                if not row: raise ToolError('Set the agenda first.')
                focus = args['focus']
                if not tools.map.value("select exists(select 1 from memory.review_candidates where kind=%s and ref_id=%s and revision=%s and action is distinct from 'dismiss' and (action is distinct from 'defer' or review_after<=current_date))",(focus['kind'],focus['ref_id'],focus['revision'])):
                    raise ToolError('Choose an unresolved item from the current queue.')
                tools.map.execute('update memory.routine_progress set review_focus=%s where conversation_id=%s',(jsonb(focus),conversation))
                if focus['kind']=='question':
                    tools.map.execute('update memory.questions set times_asked=times_asked+1,asked_at=now(),asked_in=%s where id::text=%s and asked_in is distinct from %s',(conversation,focus['ref_id'],conversation))
            elif args.get('finish'):
                if not tools.message_id or not tools.map.value("select role='user' from memory.messages where id=%s",(tools.message_id,)):
                    raise ToolError('End early at the user’s request, not because work was overlooked.')
                tools.map.execute('update memory.routine_progress set ended_at=clock_timestamp() where conversation_id=%s',(conversation,))
            elif 'steps' in args:
                rules=args.get('rule_ids',[])
                if len(set(args['steps']))!=len(args['steps']): raise ToolError('Each agenda section must be distinct.')
                if rules and tools.map.value("select count(*) from memory.rules where id=any(%s) and status='active'",(rules,))!=len(set(rules)):
                    raise ToolError('Use active saved preference IDs.')
                if row:
                    if not args.get('change_reason') or args['steps'][:row['position']]!=row['steps'][:row['position']]:
                        raise ToolError('To revise the remaining agenda, give the user-requested change and preserve completed sections.')
                    tools.map.execute('update memory.routine_progress set steps=%s,rule_ids=%s,updated_at=clock_timestamp() where conversation_id=%s',(jsonb(args['steps']),rules,conversation))
                else:
                    tools.map.execute('insert into memory.routine_progress(conversation_id,steps,rule_ids) values(%s,%s,%s)',(conversation,jsonb(args['steps']),rules))
            elif args.get('completed_step'):
                if not row: raise ToolError('Set the agenda first.')
                position=row['position']
                if args['completed_step'] in row['steps'][:position]: return progress(tools.map,conversation)
                if position==len(row['steps']) or row['steps'][position]!=args['completed_step']:
                    raise ToolError('Only the current section can be completed or skipped.')
                tools.map.execute('update memory.routine_progress set position=position+1,updated_at=clock_timestamp() where conversation_id=%s',(conversation,))
            return progress(tools.map,conversation)
    return ToolSpec('routine_progress','Lead the saved routine. Set its agenda from preferences, complete sections, and use the returned next_action. Select review focus before asking a consequential question; save the answer with memory_clarify/plan_update. The review field defers or dismisses attention, never completes the underlying task. Finish when the user is done. Progress survives reconnections. Save standing changes with preference_save.',
        _obj({'steps':{'type':'array','minItems':1,'maxItems':30,'items':_s('One concise section name',minLength=1,maxLength=120)},
              'rule_ids':{'type':'array','items':_i('Active preference rule ID')},'completed_step':_s('Exact current section name'),
              'focus':_obj({'kind':_s('Subject',enum=['plan','question']),'ref_id':_s('Queue ID'),'revision':_s('Queue revision')},['kind','ref_id','revision']),
              'review':review_queue.schema(),'finish':{'type':'boolean','description':'User asked to stop. Pending work is preserved for a later review.'},
              'change_reason':_s('User-requested change when revising remaining steps; preserve the completed prefix')},[]),update)
