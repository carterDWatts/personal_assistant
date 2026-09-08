from unittest import TestCase
from unittest.mock import patch
from engine.integrations.news import parse, fetch, headlines
import asyncio

class news_test(TestCase):
    def test_only_published_links_and_headlines_are_exposed(self):
        data = b'<rss><channel><item><title>A &amp; B</title><link>https://www.nytimes.com/a</link><description>Full body is not imported</description><pubDate>Today</pubDate></item><item><title>Bad</title><link>https://nytimes.com.evil.test/</link></item></channel></rss>'
        self.assertEqual(parse(data), [{'headline':'A & B','url':'https://www.nytimes.com/a','published_at':'Today'}])
    def test_unknown_sections_cannot_fetch_arbitrary_urls(self):
        with self.assertRaises(ValueError): fetch('http://localhost')
    def test_failure_is_explicit(self):
        with patch('engine.integrations.news.fetch', side_effect=TimeoutError):
            self.assertIn('error', asyncio.run(headlines({})))
    def test_morning_does_not_fetch_news_by_default(self):
        from engine.morning import prepare
        from unittest.mock import AsyncMock
        with patch('engine.morning.run',new=AsyncMock(return_value=('available',False))) as run:
            asyncio.run(prepare(None))
        self.assertNotIn('news_headlines',[call.args[0].name for call in run.call_args_list])
