import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from engine.desktop import load_settings


class desktop_test(unittest.TestCase):
    def test_settings_are_literal_and_do_not_execute_shell(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            (root/'.zshrc').write_text("export ASSISTANT_DATABASE_URL='postgresql://example:a$!b@host/db'\nexport ASSISTANT_TEST_DATABASE_URL=$(touch should-not-exist)\nexport UNRELATED_SECRET='ignored'\n")
            with patch('engine.desktop.Path.home',return_value=root), patch.dict(os.environ,{},clear=True):
                load_settings()
                self.assertEqual(os.environ['ASSISTANT_DATABASE_URL'],'postgresql://example:a$!b@host/db')
                self.assertNotIn('ASSISTANT_TEST_DATABASE_URL',os.environ)
                self.assertNotIn('UNRELATED_SECRET',os.environ)
                self.assertFalse((root/'should-not-exist').exists())

    def test_explicit_environment_takes_precedence(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);(root/'.zshrc').write_text("export ASSISTANT_DATABASE_URL='profile'\n")
            with patch('engine.desktop.Path.home',return_value=root),patch.dict(os.environ,{'ASSISTANT_DATABASE_URL':'explicit'},clear=True):
                load_settings()
                self.assertEqual(os.environ['ASSISTANT_DATABASE_URL'],'explicit')
