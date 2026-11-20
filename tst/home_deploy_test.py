import base64
import hashlib
import hmac
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


class HomeKeysTest(unittest.TestCase):
    def test_keys_are_private_valid_and_preserved_on_rerun(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            script = root / 'keys.py'
            shutil.copy(Path(__file__).parents[1] / 'deploy/home/keys.py', script)
            env = root / '.env'
            env.write_text('POSTGRES_PASSWORD=keep\nJWT_SECRET=\nANON_KEY=\nSERVICE_ROLE_KEY=\n')
            subprocess.run([sys.executable, str(script)], check=True, capture_output=True)
            first = env.read_bytes()
            values = dict(line.split('=', 1) for line in first.decode().splitlines() if '=' in line)
            self.assertEqual(values['POSTGRES_PASSWORD'], 'keep')
            self.assertEqual(env.stat().st_mode & 0o777, 0o600)
            for name, role in [('ANON_KEY', 'anon'), ('SERVICE_ROLE_KEY', 'service_role')]:
                head, body, signature = values[name].split('.')
                decode = lambda value: base64.urlsafe_b64decode(value + '=' * (-len(value) % 4))
                expected = hmac.new(values['JWT_SECRET'].encode(), (head + '.' + body).encode(), hashlib.sha256).digest()
                self.assertEqual(decode(signature), expected)
                self.assertEqual(json.loads(decode(body))['role'], role)
            subprocess.run([sys.executable, str(script)], check=True, capture_output=True)
            self.assertEqual(env.read_bytes(), first)

    def test_partial_existing_keys_are_not_rotated(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            script = root / 'keys.py'
            shutil.copy(Path(__file__).parents[1] / 'deploy/home/keys.py', script)
            env = root / '.env'
            env.write_text('JWT_SECRET=existing\n')
            result = subprocess.run([sys.executable, str(script)], capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(env.read_text(), 'JWT_SECRET=existing\n')
