import asyncio
import unittest
from unittest.mock import patch, Mock
from engine.integrations.discovery import adapter, discover, connect, ConnectionPage
from engine.tools import ConnectionRequired, ToolError


class DiscoveryTest(unittest.TestCase):
    def test_adapter_matching_cannot_be_spoofed(self):
        self.assertEqual(adapter('https://api.github.com')[0], 'github')
        self.assertIsNone(adapter('https://github.com.attacker.example'))
        self.assertIsNone(adapter('https://github.com@attacker.example'))

    def test_unknown_service_returns_evidence_not_an_unsupported_claim(self):
        def read(url):
            if url == 'https://unlisted.example':
                return {'url':url,'links':[{'url':'https://developer.unlisted.example/connect','text':'Developer API'}]}
            if url.endswith('/connect'):
                return {'url':url,'text':'Register an OAuth application in the developer portal.'}
            return {'url':url,'status':404}
        with patch('engine.integrations.discovery.inspect',side_effect=read):
            result=discover({'url':'https://unlisted.example','task':'Read my projects'})
        self.assertEqual(result['state'],'research_required')
        self.assertIsNone(result['connection'])
        self.assertTrue(any('Register an OAuth' in e.get('text','') for e in result['evidence']))
        self.assertNotIn('url',result.get('connection') or {})

    def test_metadata_does_not_claim_a_working_connector(self):
        with patch('engine.integrations.discovery.inspect',side_effect=lambda url:{'url':url,'metadata':{'registration_endpoint':'https://login.unlisted.example/register','client_secret':'never-return-this'}}):
            result=discover({'url':'https://unlisted.example','task':'Read projects'})
        self.assertEqual(result['state'],'research_required')
        self.assertNotIn('client_secret',str(result))
        self.assertIn('generic MCP authorization and execution are not implemented',result['next_step'])

    def test_navigation_links_are_discoverable(self):
        page=ConnectionPage('https://unlisted.example')
        page.feed('<nav><a href="/developers">Developers</a></nav>')
        self.assertEqual(page.links[0]['url'],'https://unlisted.example/developers')

    def test_existing_adapter_offers_the_native_connection(self):
        with self.assertRaises(ConnectionRequired) as result:
            asyncio.run(connect({'url':'https://github.com'}))
        self.assertEqual(result.exception.action,'github_connect')
        with self.assertRaises(ToolError):
            asyncio.run(connect({'url':'https://unlisted.example'}))
