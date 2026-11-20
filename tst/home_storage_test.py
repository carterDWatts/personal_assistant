import os
import unittest
from unittest.mock import patch

from engine.images import Storage as ImageStorage
from engine.speech import Storage as SpeechStorage


class HomeStorageTest(unittest.TestCase):
    def test_signed_media_uses_public_address_without_sending_credentials_there(self):
        for storage_type in (ImageStorage, SpeechStorage):
            for public_url in ('https://home.example:10000/', None):
                env = {'ASSISTANT_STORAGE_KEY': 'private', 'ASSISTANT_SUPABASE_URL': 'http://api:8000'}
                if public_url:
                    env['ASSISTANT_PUBLIC_URL'] = public_url
                with self.subTest(storage=storage_type, public_url=public_url), patch.dict(os.environ, env, clear=True):
                    storage = storage_type()
                    self.assertEqual(storage.url, 'http://api:8000')
                    with patch.object(storage, 'request', return_value={'signedURL': '/object/sign/file?token=signed'}):
                        url = storage.signed('file') if storage_type is ImageStorage else storage.upload('file', b'audio')
                    self.assertEqual(url, (public_url or storage.url).rstrip('/') + '/storage/v1/object/sign/file?token=signed')
