from datetime import date, timedelta
from tst import tools_test
from tst.helpers import MapTest


class plans_test(MapTest):
    def setUp(self):
        super().setUp()
        from engine.tools import Tools
        self.tools=Tools(self.map,'test')
        self.by_name={t.name:t for t in self.tools.specs()}
    call = tools_test.tools_test.call
    def test_exact_duplicate_does_not_resurrect_a_completed_plan(self):
        p=self.call('plan_add',day='today',item='Call the dentist')
        q=self.call('plan_add',day='today',item=' call   the dentist ')
        self.assertEqual(p['id'],q['id'])
        done=self.call('plan_update',plan_id=p['id'],version=p['version'],status='done',note='User confirmed the call')
        self.assertEqual(self.call('plan_add',day='today',item='Call the dentist')['status'],'done')
        self.assertEqual(done['version'],2)

    def test_correction_reschedule_and_stale_writer_preserve_history(self):
        p=self.call('plan_add',day='today',item='Book a flight')
        moved=self.call('plan_update',plan_id=p['id'],version=1,day='tomorrow',item='Compare flight prices',note='User postponed and changed scope')
        self.assertEqual(moved['day'],(date.today()+timedelta(days=1)).isoformat())
        self.assertIn('error',self.call('plan_update',plan_id=p['id'],version=1,status='done',note='Stale worker'))
        history=self.call('plan_history',plan_id=p['id'])
        self.assertEqual(history[0]['previous']['item'],'Book a flight')
        self.assertEqual(history[0]['replacement']['item'],'Compare flight prices')
        self.assertIsNotNone(history[0]['replacement']['last_observation_id'])

    def test_review_does_not_infer_completion_and_old_tasks_are_searchable(self):
        p=self.call('plan_add',day='2020-01-01',item='An unresolved commitment')
        notes=self.map.rows('select * from memory.plan_notes(%s)',(date.today(),))
        self.assertEqual(notes[0]['section'],'review')
        self.assertEqual(notes[0]['status'],'planned')
        self.assertEqual(self.call('plans_list',scope='open',query='unresolved')[0]['id'],p['id'])

    def test_merge_preserves_target_outcome_and_separate_occurrences(self):
        old=self.call('plan_add',day='today',item='Work out')
        done=self.call('plan_add',day='today',item='Gym',origin='unplanned',status='done')
        future=self.call('plan_add',day='tomorrow',item='Gym')
        self.assertIn('error',self.call('plan_merge',plan_id=future['id'],version=1,into_id=done['id'],into_version=1,note='Different days'))
        self.call('plan_merge',plan_id=old['id'],version=1,into_id=done['id'],into_version=1,note='User confirmed these refer to the same workout')
        self.assertEqual(len(self.call('plans_list',day='today')),1)
        self.assertEqual(self.call('plans_list',day='today')[0]['status'],'done')
        self.assertTrue(self.call('plan_history',plan_id=old['id']))

    def test_plan_answer_closes_its_question_in_the_same_transaction(self):
        p=self.call('plan_add',day='yesterday',item='Call')
        q=self.call('question_add',text='Did the call happen?',ref_table='plans',ref_id=str(p['id']))
        again=self.call('question_add',text='Is the call still relevant?',ref_table='plans',ref_id=str(p['id']))
        self.assertEqual(q['id'],again['id'])
        self.call('plan_update',plan_id=p['id'],version=1,status='dropped',note='User no longer needs the call')
        self.assertIsNotNone(self.map.value('select closed_at from memory.questions where id=%s',(q['id'],)))

    def test_duplicate_completion_requires_an_explicit_update(self):
        self.call('plan_add',day='today',item='Call')
        self.assertIn('error',self.call('plan_add',day='today',item='Call',status='done'))

    def test_rewording_does_not_answer_an_outcome_question(self):
        p=self.call('plan_add',day='yesterday',item='Call')
        q=self.call('question_add',text='Did the call happen?',ref_table='plans',ref_id=str(p['id']))
        self.call('plan_update',plan_id=p['id'],version=1,item='Call the dentist',note='Clarified who the call is with')
        self.assertIsNone(self.map.value('select closed_at from memory.questions where id=%s',(q['id'],)))

    def test_future_completion_and_late_extraction_cannot_overwrite_truth(self):
        self.assertIn('error',self.call('plan_add',day='tomorrow',item='Workout',status='done'))
        p=self.call('plan_add',day='today',item='Call')
        self.call('plan_update',plan_id=p['id'],version=1,status='done',note='User confirmed the call')
        from datetime import datetime,timezone
        self.tools.observed_at=datetime(2020,1,1,tzinfo=timezone.utc)
        self.assertIn('error',self.call('plan_update',plan_id=p['id'],version=2,status='planned',note='An earlier statement'))
        self.assertEqual(self.map.value('select status from memory.plans where id=%s',(p['id'],)),'done')
