"""Progress belongs to a morning conversation, not a model's recollection of it."""
from engine.db import jsonb
from engine.tools import ToolError, ToolSpec, _obj, _s, _i


def progress(map_, conversation):
    row=map_.row('select steps,position,rule_ids from memory.routine_progress where conversation_id=%s',(conversation,))
    if not row: return {'state':'not_started','instruction':'Build the agenda from active saved preferences; do not invent required sections.'}
    return {**row,'current':row['steps'][row['position']] if row['position']<len(row['steps']) else None,
            'completed':row['steps'][:row['position']]}


def spec(tools,conversation):
    async def update(args):
        with tools.map.conn.transaction():
            tools.map.execute('select id from memory.conversations where id=%s for update',(conversation,))
            row=tools.map.row('select * from memory.routine_progress where conversation_id=%s for update',(conversation,))
            if 'steps' in args:
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
    return ToolSpec('routine_progress','Read/set this morning’s agenda from saved preferences. Mark the current section completed after covering it or when the user asks to move on; then use the returned next section. Repeated completion is idempotent. Do not revisit completed sections unless the user explicitly returns to them. This progress is not a standing preference; save routine changes separately with preference_save.',
        _obj({'steps':{'type':'array','minItems':1,'maxItems':30,'items':_s('One concise section name',minLength=1,maxLength=120)},
              'rule_ids':{'type':'array','items':_i('Active preference rule ID')},'completed_step':_s('Exact current section name'),
              'change_reason':_s('User-requested change when revising remaining steps; preserve the completed prefix')},[]),update)
