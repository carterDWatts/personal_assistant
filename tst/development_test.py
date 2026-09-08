import asyncio
import os
from types import SimpleNamespace
from unittest import TestCase
from unittest.mock import Mock,patch
from engine.development import Development,validate_files
from engine.tools import ToolError

class development_test(TestCase):
    def setUp(self):
        self.env=patch.dict(os.environ,{'ASSISTANT_DEVELOPER_OWNER':'owner','ASSISTANT_DEVELOPER_REPO':'example/assistant','ASSISTANT_DEVELOPER_PROJECT':'abcdefghijklmnopqrst'})
        self.env.start();self.addCleanup(self.env.stop)
        self.map=Mock();self.map.value.return_value='owner'
        self.dev=Development(SimpleNamespace(map=self.map))

    def test_another_owner_is_denied(self):
        self.map.value.return_value='another-owner'
        with self.assertRaises(ToolError):self.dev.specs()

    def test_disabled_installation_has_no_development_tools(self):
        with patch.dict(os.environ,{'ASSISTANT_DEVELOPER_OWNER':''}):self.assertEqual(self.dev.specs(),[])

    def test_paths_credentials_and_test_runner_are_protected(self):
        for files in ({'../secret.py':'x'},{'.github/workflows/test.yml':'x'},{'scripts/test.sh':'exit 0'},{'engine/key.py':'ghp_'+'a'*36}):
            with self.assertRaises(ToolError):validate_files(files)
        validate_files({'engine/example.py':'print("hello")\n'})

    def test_stale_main_cannot_be_published(self):
        self.dev.github=Mock(return_value={'object':{'sha':'b'*40}})
        with self.assertRaises(ToolError):asyncio.run(self.dev.publish({'files':{'engine/a.py':'pass'},'base_sha':'a'*40}))
        self.assertEqual(self.dev.github.call_count,1)

    def pr(self):
        return {'head':{'repo':{'full_name':'example/assistant'},'ref':'assistant/test','sha':'a'*40},'base':{'ref':'main'},'state':'open'}

    def test_merge_requires_successful_trusted_check(self):
        self.dev.github=Mock(side_effect=[self.pr(),{'check_runs':[{'name':'assistant-tests','app':{'slug':'other-app'},'conclusion':'success'}]}])
        with self.assertRaises(ToolError):asyncio.run(self.dev.merge({'number':1,'sha':'a'*40}))
        self.assertEqual(self.dev.github.call_count,2)

    def test_merge_is_bound_to_checked_revision(self):
        self.dev.github=Mock(side_effect=[self.pr(),{'check_runs':[{'name':name,'app':{'slug':'github-actions'},'conclusion':'success'} for name in ('assistant-tests','assistant-apps')]},{'merged':True,'sha':'b'*40}])
        self.assertTrue(asyncio.run(self.dev.merge({'number':1,'sha':'a'*40}))['merged'])
        self.dev.github.assert_called_with('pulls/1/merge',{'sha':'a'*40,'merge_method':'squash'},'PUT')

    def test_transaction_control_cannot_escape_migration(self):
        import base64
        self.dev.github=Mock(side_effect=[{'object':{'sha':'a'*40}},{'encoding':'base64','content':base64.b64encode(b'COMMIT; SELECT 1;').decode()}])
        with self.assertRaises(ToolError):asyncio.run(self.dev.migrate({'path':'supabase/migrations/20260909000000_test.sql','sha':'a'*40}))
        self.map.conn.transaction.assert_not_called()

from tst.helpers import MapTest

class development_migration_test(MapTest):
    def setUp(self):
        super().setUp()
        self.map.execute('create schema if not exists supabase_migrations')
        self.map.execute('create table if not exists supabase_migrations.schema_migrations(version text primary key,name text,statements text[])')
        self.map.execute("delete from supabase_migrations.schema_migrations where version='20990101000000'")
        self.map.execute('drop table if exists memory.owner_migration_check')
        self.map.url='postgresql://postgres.abcdefghijklmnopqrst@localhost/postgres'
        self.dev=Development(SimpleNamespace(map=self.map))
        self.dev.scope=Mock(return_value=('example/assistant','abcdefghijklmnopqrst'))

    def apply(self,sql):
        import base64
        self.dev.github=Mock(side_effect=[{'object':{'sha':'a'*40}},{'encoding':'base64','content':base64.b64encode(sql.encode()).decode()}])
        return self.run_async(self.dev.migrate({'path':'supabase/migrations/20990101000000_check.sql','sha':'a'*40}))

    def test_success_is_recorded_once(self):
        self.assertEqual(self.apply('create table memory.owner_migration_check(id int);')['status'],'applied')
        self.assertEqual(self.apply('create table memory.owner_migration_check(id int);')['status'],'already_applied')
        self.assertEqual(self.map.value("select count(*) from supabase_migrations.schema_migrations where version='20990101000000'"),1)

    def test_failure_rolls_back_schema_and_ledger(self):
        with self.assertRaises(Exception):self.apply('create table memory.owner_migration_check(id int); select missing_column;')
        self.assertIsNone(self.map.value("select to_regclass('memory.owner_migration_check')"))
        self.assertEqual(self.map.value("select count(*) from supabase_migrations.schema_migrations where version='20990101000000'"),0)
