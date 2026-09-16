from unittest import TestCase
from engine.db import transport_options


class DatabaseTransport(TestCase):
    def test_supabase_cannot_silently_downgrade_tls(self):
        options = transport_options('postgresql://user@aws-0-us-east-2.pooler.supabase.com/postgres?sslmode=disable')
        self.assertEqual(options['sslmode'], 'verify-full')
        self.assertTrue(options['sslrootcert'].endswith('/deploy/supabase-ca.crt'))

    def test_host_trust_bundle_is_preserved(self):
        options = transport_options('host=db.example.supabase.co sslrootcert=/etc/ssl/certs/ca-certificates.crt')
        self.assertEqual(options, {'sslmode': 'verify-full'})

    def test_local_test_database_is_unaffected(self):
        self.assertEqual(transport_options('postgresql://postgres@localhost:55432/test'), {})
