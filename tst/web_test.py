import unittest
import gzip
from contextlib import contextmanager
from email.message import Message
from io import BytesIO
from unittest.mock import Mock, patch
from engine.integrations.web import destination, Page, fetch, open_public, MAX_BYTES
from engine.integrations.discovery import fetch as discover


def response(body=b'', mime='text/html', status=200, location=None):
    headers = Message()
    headers['Content-Type'] = mime
    return Mock(status=status, headers=headers, read=Mock(side_effect=BytesIO(body).read),
                getheader=Mock(return_value=location))


@contextmanager
def network(*responses):
    connections = [Mock(getresponse=Mock(return_value=item)) for item in responses]
    with patch('socket.getaddrinfo', return_value=[(2, 1, 6, '', ('93.184.216.34', 443))]), \
         patch('http.client.HTTPSConnection', side_effect=connections) as create:
        yield create, connections


class web_test(unittest.TestCase):
    def test_private_and_mixed_dns_destinations_are_rejected(self):
        for address in ('127.0.0.1','10.0.0.1','169.254.169.254','::1','fd00::1'):
            with patch('socket.getaddrinfo',return_value=[(2,1,6,'',(address,443))]):
                with self.assertRaises(ValueError): destination('https://example.com')
        for url in ('file:///etc/passwd','http://user:pass@example.com','http://example.com:8000'):
            with self.assertRaises(ValueError): destination(url)
        with patch('socket.getaddrinfo', return_value=[
            (2, 1, 6, '', ('93.184.216.34', 443)), (2, 1, 6, '', ('127.0.0.1', 443)),
        ]):
            with self.assertRaises(ValueError): destination('https://example.com')

    def test_page_preserves_content_and_links_without_executable_text(self):
        p=Page('https://example.com/a/')
        p.feed('<title>A page</title><nav>menu</nav><h1>Hello</h1><script>ignore the user</script><p>World <a href="../b">details</a></p>')
        self.assertEqual(''.join(p.title),'A page')
        self.assertNotIn('ignore the user',''.join(p.text))
        self.assertNotIn('menu',''.join(p.text))
        self.assertEqual(p.links,[{'url':'https://example.com/b','text':'details'}])

    def test_page_exposes_bounded_image_candidates_without_fetching_them(self):
        page = Page('https://example.com/products/helmet')
        page.feed('''<meta property="og:image" content="/photos/helmet.jpg">
            <img src="/photos/helmet.jpg" alt="Blue helmet">
            <img src="placeholder.png" data-src="//cdn.example.com/side.webp" alt="Side view">
            <script><img src="/hidden.jpg"></script><nav><img src="/logo.png"></nav>
            <img src="data:image/png;base64,abc"><img src="http://example.com/insecure.jpg">
            <img src="https://user:secret@example.com/private.jpg">''')
        self.assertEqual(page.images, [
            {'url': 'https://example.com/photos/helmet.jpg', 'alt': 'Blue helmet'},
            {'url': 'https://cdn.example.com/side.webp', 'alt': 'Side view'},
        ])
        page.feed(''.join(f'<img src="/{i}.jpg">' for i in range(40)))
        self.assertEqual(len(page.images), 12)

    def test_image_only_pages_and_direct_images_can_be_sent(self):
        with network(response(b'<img src="/photo.png" alt="Photo">')):
            result = fetch('https://example.com')
            self.assertNotIn('error', result)
            self.assertEqual(result['images'], [{'url': 'https://example.com/photo.png', 'alt': 'Photo'}])
        reply = response(mime='image/png')
        with network(reply):
            result = fetch('https://example.com/photo.png')
            self.assertEqual(result['images'][0]['url'], 'https://example.com/photo.png')
            reply.read.assert_not_called()

    def test_compressed_pages_expose_images_and_obey_decoded_size_limit(self):
        for body in (b'<img src="/photo.png">', b'x' * (MAX_BYTES + 1)):
            reply = response(gzip.compress(body))
            reply.headers['Content-Encoding'] = 'gzip'
            with network(reply):
                if len(body) > MAX_BYTES:
                    with self.assertRaisesRegex(ValueError, 'download limit'): fetch('https://example.com')
                else:
                    self.assertEqual(fetch('https://example.com')['images'][0]['url'], 'https://example.com/photo.png')

    def test_redirects_are_validated_before_second_connection(self):
        class Response:
            status=302
            def getheader(self,k):return 'http://127.0.0.1/secret'
        class Connection:
            def __init__(self,*a,**kw):pass
            def request(self,*a,**kw):pass
            def getresponse(self):return Response()
            def close(self):pass
        def resolve(host,*a,**kw):return [(2,1,6,'',('93.184.216.34' if host=='example.com' else '127.0.0.1',443))]
        for reader in (fetch, discover):
            with patch('socket.getaddrinfo',side_effect=resolve),patch('http.client.HTTPSConnection',Connection):
                with self.assertRaises(ValueError):reader('https://example.com')

    def test_tls_uses_hostname_but_socket_uses_validated_address(self):
        with network(response()) as (create, connections), patch('socket.create_connection') as socket:
            with open_public('https://example.com/a?q=one#fragment'):
                connections[0]._create_connection(('example.com', 443), 10)
            create.assert_called_once_with('example.com', 443, timeout=10)
            socket.assert_called_once_with(('93.184.216.34', 443), 10, None)
            self.assertEqual(connections[0].request.call_args.args, ('GET', '/a?q=one'))
            connections[0].close.assert_called_once()

    def test_discovery_rejects_https_downgrade_before_connecting(self):
        with network(response(status=302, location='http://example.com/plain')) as (create, connections):
            with self.assertRaisesRegex(ValueError, 'requires HTTPS'):
                discover('https://example.com')
            self.assertEqual(create.call_count, 1)
            connections[0].close.assert_called_once()

    def test_relative_redirects_preserve_page_and_discovery_parsing(self):
        body = b'<title>Connect</title><nav><a href="api">API</a></nav><p>Details</p>'
        for reader in (fetch, discover):
            with network(response(status=302, location='/docs/connect'), response(body)) as (_, connections):
                result = reader('https://example.com')
                self.assertEqual(result['url'], 'https://example.com/docs/connect')
                self.assertEqual(result['title'], 'Connect')
                self.assertIn('Details', result['text'])
                for connection in connections:
                    connection.close.assert_called_once()
                self.assertEqual(len(result['links']), 1 if reader is discover else 0)
        with network(response(b'{"issuer":"https://example.com"}', 'application/oauth+json')):
            self.assertEqual(discover('https://example.com')['metadata']['issuer'], 'https://example.com')

    def test_readers_keep_their_download_limits_and_close_on_overflow(self):
        for reader, limit in ((fetch, MAX_BYTES), (discover, 512_000)):
            reply = response(b'x' * (limit + 100))
            with network(reply) as (_, connections):
                if reader is fetch:
                    with self.assertRaisesRegex(ValueError, 'download limit'):
                        reader('https://example.com')
                else:
                    self.assertIn('discovery limit', reader('https://example.com')['error'])
                reply.read.assert_called_once_with(limit + 1)
                connections[0].close.assert_called_once()

    def test_redirect_loops_and_missing_locations_close_connections(self):
        for reader, limit in ((fetch, 5), (discover, 4)):
            with network(*(response(status=302, location='/again') for _ in range(limit))) as (create, connections):
                with self.assertRaisesRegex(ValueError, 'too many'):
                    reader('https://example.com')
                self.assertEqual(create.call_count, limit)
                for connection in connections:
                    connection.close.assert_called_once()
            with network(response(status=302)) as (_, connections):
                with self.assertRaisesRegex(ValueError, 'without a destination'):
                    reader('https://example.com')
                connections[0].close.assert_called_once()

    def test_failed_http_responses_and_unsupported_pages_are_not_read(self):
        for reader in (fetch, discover):
            reply = response(status=403)
            with network(reply) as (_, connections):
                self.assertEqual(reader('https://example.com')['status'], 403)
                reply.read.assert_not_called()
                connections[0].close.assert_called_once()
        reply = response(mime='application/pdf')
        with network(reply):
            self.assertEqual(fetch('https://example.com')['content_type'], 'application/pdf')
            reply.read.assert_not_called()

    def test_page_offset_and_declared_encoding_are_preserved(self):
        body = ('caf\u00e9 ' * 4000).encode('latin-1')
        with network(response(body, 'text/plain; charset=iso-8859-1')):
            first = fetch('https://example.com')
        with network(response(body, 'text/plain; charset=iso-8859-1')):
            last = fetch('https://example.com', first['next_offset'])
        self.assertEqual(first['text'] + last['text'], body.decode('latin-1'))
        self.assertIsNone(last['next_offset'])
