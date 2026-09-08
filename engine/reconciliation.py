"""Evidence-backed inference and atomic resolution of memory questions."""
from datetime import datetime, timezone
from jsonschema import validate
from engine.db import dumps, jsonb
from engine.tools import ToolSpec, ToolError, _obj, _s, _i, run

REF = _obj({'kind':_s('record type',enum=['assertions','relationships']), 'id':_s('record UUID')},['kind','id'])

class Reconciliation:
    def __init__(self, tools): self.tools=tools;self.map=tools.map

    async def infer(self,args):
        """A new inference cannot replace an existing belief or depend on another guess."""
        specs={s.name:s for s in self.tools.specs()}
        with self.map.conn.transaction():
            sources=[];seen=set()
            for ref in sorted(args['evidence'],key=lambda r:(r['kind'],r['id'])):
                if (ref['kind'],ref['id']) in seen: continue
                seen.add((ref['kind'],ref['id']))
                row=self.map.row(f"select * from memory.{ref['kind']} where id=%s for share",(ref['id'],))
                if not row or row['rank']=='deprecated' or row['level']=='inferred' or not self.map.value('select %s::tstzrange @> now()',(row['valid'],)):
                    raise ToolError('Evidence must be current, non-deprecated, independently stated or synced records.')
                sources.append((ref,row))
            if len(sources)<2: raise ToolError('Give at least two distinct evidence records.')
            name=args['tool'];values=dict(args['arguments'])
            validate(values,specs[name].schema)
            if name=='fact_assert':
                occupied=self.map.value("select exists(select 1 from memory.assertions where entity_id=%s and attribute=%s and rank<>'deprecated' and valid @> now())",(values['entity_id'],values['attribute']))
            else:
                occupied=self.map.value("select exists(select 1 from memory.relationships where subject_id=%s and relation=%s and rank<>'deprecated' and valid @> now() and (cardinality='single' or object_id=%s))",(values['subject_id'],values['relation'],values['object_id']))
            if name=='fact_assert':
                rejected=self.map.value("select exists(select 1 from memory.assertions where entity_id=%s and attribute=%s and value=%s and rank='deprecated' and resolution_reason is not null)",(values['entity_id'],values['attribute'],jsonb(values['value'])))
            else:
                rejected=self.map.value("select exists(select 1 from memory.relationships where subject_id=%s and relation=%s and object_id=%s and rank='deprecated' and resolution_reason is not null)",(values['subject_id'],values['relation'],values['object_id']))
            if rejected: raise ToolError('This claim was corrected or invalidated. Queue a review question; do not infer it again.')
            if occupied: raise ToolError('Existing beliefs must be resolved through a clarification, not replaced by nightly inference.')
            # Bound the inference to the common evidence interval, including automatic expiry.
            start=max(row['valid'].lower for _,row in sources)
            ends=[row['valid'].upper for _,row in sources if row['valid'].upper]
            values.update(level='inferred',confidence=min(float(values.get('confidence',.7)),.85),valid_from=start.isoformat(),statement=args['rationale'])
            values.pop('valid_to',None)
            if ends: values['valid_to']=min(ends).isoformat()
            result,failed=await run(specs[name],values)
            if failed: raise ToolError(result)
            import json
            record=json.loads(result)
            target='assertion_id' if name=='fact_assert' else 'relationship_id'
            for ref,_ in sources:
                source='source_assertion_id' if ref['kind']=='assertions' else 'source_relationship_id'
                self.map.execute(f'insert into memory.derivations({target},{source},rationale) values(%s,%s,%s)',(record['id'],ref['id'],args['rationale']))
            return record

    def nightly_specs(self):
        specs={s.name:s for s in self.tools.specs()}
        # Registration permits new vocabulary; it cannot mutate existing definitions.
        return [specs[n] for n in ('attribute_register','relation_register','map_search','entity_view','fact_history')]+[
            ToolSpec('derive_memory','Build a new inferred fact or relationship from at least two current stated/synced records. Never overwrite a belief. Register new vocabulary first.',
                _obj({'tool':_s('operation',enum=['fact_assert','relationship_assert']), 'arguments':{'type':'object'},
                      'evidence':{'type':'array','minItems':2,'maxItems':8,'items':REF},'rationale':_s('Explain the connection and its limitations.')},['tool','arguments','evidence','rationale']),self.infer)]

    async def resolve(self,args):
        from engine.memory_worker import resolve_refs
        message=self.map.row('select role,content,payload from memory.messages where id=%s',(self.tools.message_id,)) if self.tools.message_id else None
        if not message or message['role']!='user' or (message['payload'] or {}).get('external'):
            raise ToolError('A clarification requires a direct user answer, not an external source or nightly inference.')
        specs={s.name:s for s in self.tools.specs()}
        allowed={'fact_assert','fact_deprecate','fact_retract','fact_confirm','relationship_assert','relationship_retract','relationship_deprecate','attribute_register','relation_register'}
        with self.map.conn.transaction():
            question=self.map.row('select * from memory.questions where id=%s for update',(args['question_id'],)) if args.get('question_id') else None
            if args.get('question_id') and not question: raise ToolError('Unknown question.')
            if question and question['closed_at']: return {'saved':True,'already_resolved':True}
            ids={}
            for op in args['operations']:
                if op['tool'] not in allowed: raise ToolError('Only memory corrections belong in a clarification.')
                values=resolve_refs(op['arguments'],ids)
                # Preserve the actual answer, not an invented quotation.
                if 'statement' in specs[op['tool']].schema['properties']: values['statement']=message['content']
                if op['tool'] in ('fact_assert','relationship_assert'): values['level']='stated';values['confidence']=1.0
                result,failed=await run(specs[op['tool']],values)
                if failed: raise ToolError(result)
                if op['tool'] in ('fact_assert','relationship_assert','fact_confirm'):
                    import json
                    confirmed=json.loads(result)
                    table='relationships' if op['tool']=='relationship_assert' else 'assertions'
                    self.map.execute(f"update memory.{table} set level='stated',confidence=1 where id=%s",(confirmed['id'],))
                if op.get('as'):
                    import json
                    ids[op['as']]=json.loads(result)['id']
            if question: self.map.execute("update memory.questions set answer=%s,closed_at=now(),closed_reason='answered' where id=%s",(message['content'],question['id']))
            return {'saved':True}

    async def preference(self,args):
        message=self.map.row('select role,content from memory.messages where id=%s',(self.tools.message_id,)) if self.tools.message_id else None
        if not message or message['role']!='user': raise ToolError('A standing preference requires a direct user statement.')
        with self.map.conn.transaction():
            for id in sorted(set(args.get('replaces',[]))):
                row=self.map.row("select * from memory.rules where id=%s for update",(id,))
                if not row or row['kind']!='preference': raise ToolError('Only existing preference rules can be replaced here.')
                await self.tools.rule_update({'rule_id':id,'status':'retired'})
            existing=self.map.row("select * from memory.rules where kind='preference' and status='active' and text=%s",(args['text'],))
            return existing or await self.tools.rule_add({'kind':'preference','text':args['text'],'status':'active','statement':message['content']})

    def conversation_specs(self):
        return [ToolSpec('preference_save','Save an explicit standing preference immediately. This includes whether to include news at all, sources, morning order, depth and interaction style. Replace superseded preference IDs atomically. Never turn a suggestion or inferred interest into an active preference.', _obj({'text':_s('standing preference in plain language'),'replaces':{'type':'array','items':{'type':'integer'}}},['text']),self.preference), ToolSpec('memory_clarify','Apply an authoritative direct user correction, or resolve a queued question from the user’s answer and commit all corrections atomically. Deprecate never-true claims; retract genuinely ended states with a known end time and reason. Do not invent dates. Read linked records before changing them.',
            _obj({'question_id':_i('queued question ID; omit for a direct correction'),'operations':{'type':'array','minItems':1,'maxItems':12,'items':_obj({'tool':_s('memory operation'),'arguments':{'type':'object'},'as':_s('optional result reference')},['tool','arguments'])}},['operations']),self.resolve)]
