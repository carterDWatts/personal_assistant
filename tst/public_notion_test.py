import json
import unittest
from unittest.mock import patch
from engine.integrations.web import fetch, read, MAX_BYTES
from engine.integrations.public_notion import page_id
from tst.web_test import network, response

ROOT = '877fc6a4-6be3-835f-bb01-019b24e001f8'
URL = 'https://example.notion.site/Example-' + ROOT.replace('-', '')


def page(blocks, cursor=None):
    return response(json.dumps({'recordMap': {'block': blocks}, 'cursor': cursor or {'stack': []}}).encode(), 'application/json')


def block(kind, text='', children=None):
    return {'value': {'type': kind, 'alive': True, 'properties': {'title': [[text]]}, 'content': children or []}}


class public_notion_test(unittest.TestCase):
    def test_public_host_and_page_id_are_required(self):
        self.assertEqual(page_id(URL + '?pvs=25'), ROOT)
        for url in ('https://notion.site.evil.test/' + ROOT, 'http://example.notion.site/' + ROOT,
                    'https://user:secret@example.notion.site/' + ROOT,
                    'https://example.notion.site:8000/' + ROOT, 'https://example.notion.site/login'):
            self.assertIsNone(page_id(url))

    def test_anonymous_read_preserves_order_links_and_ignores_unrelated_records(self):
        records = {
            ROOT: block('page', 'Profile', ['intro', 'child']),
            'intro': {'value': {'value': {'type': 'text', 'properties': {'title': [['Learn more', [['a', 'https://example.com']]]]}, 'content': [ROOT]}}},
            'child': block('page', 'Related page', ['unrelated']),
            'unrelated': block('text', 'Not part of the requested page'),
        }
        with network(page(records)) as (_, connections):
            result = fetch(URL)
            call = connections[0].request.call_args
            self.assertEqual(call.args, ('POST', '/api/v3/loadPageChunk'))
            self.assertEqual(json.loads(call.kwargs['body'])['pageId'], ROOT)
            self.assertNotIn('Authorization', call.kwargs['headers'])
            self.assertNotIn('Cookie', call.kwargs['headers'])
        self.assertEqual(result['text'], 'Profile\n\nLearn more\n\nRelated page')
        self.assertEqual(result['links'][0]['url'], 'https://example.com')
        self.assertFalse(result['incomplete'])
        self.assertNotIn('connection_action', result)

    def test_cursor_pages_and_text_offsets(self):
        replies = lambda: (page({ROOT: block('page', 'Title', ['body'])}, {'stack': [['more']]}),
                            page({'body': block('text', 'Long text. ' * 2000)}))
        with network(*replies()): first = fetch(URL)
        with network(*replies()) as (_, connections):
            last = fetch(URL, first['next_offset'])
            self.assertEqual(json.loads(connections[1].request.call_args.kwargs['body'])['cursor'], {'stack': [['more']]})
        self.assertEqual(first['text'] + last['text'], 'Title\n\n' + 'Long text. ' * 2000)
        self.assertIsNone(last['next_offset'])

    def test_denial_does_not_claim_authentication_is_required(self):
        for reply in (response(status=403), page({})):
            with network(reply): result = fetch(URL)
            self.assertIn('error', result)
            self.assertNotIn('connection_action', result)
            self.assertNotIn('text', result)

    def test_limits_and_post_redirects_are_enforced(self):
        with network(response(status=302, location='http://127.0.0.1/')) as (create, _):
            with self.assertRaisesRegex(ValueError, 'redirected unexpectedly'): fetch(URL)
            self.assertEqual(create.call_count, 1)
        with network(response(b'x' * (MAX_BYTES + 1), 'application/json')):
            with self.assertRaisesRegex(ValueError, 'download limit'): fetch(URL)
        with network(*(page({ROOT: block('page', 'Title')}, {'stack': [['more']]}) for _ in range(5))) as (create, _):
            self.assertTrue(fetch(URL)['incomplete'])
            self.assertEqual(create.call_count, 5)

    def test_unloaded_blocks_are_explicitly_incomplete(self):
        with network(page({ROOT: block('page', 'Title', ['missing'])})):
            self.assertTrue(fetch(URL)['incomplete'])

    def test_empty_html_is_a_read_failure_not_a_success_or_login_prompt(self):
        with network(response(b'<title>App</title><script>load()</script>')):
            result = fetch('https://example.com')
        self.assertIn('error', result)
        self.assertNotIn('text', result)
        self.assertNotIn('connection_action', result)
