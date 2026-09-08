import unittest
from unittest.mock import Mock, patch

from engine.integrations import calendar, google, read_specs
from engine.tools import ToolError, run


class calendar_test(unittest.IsolatedAsyncioTestCase):
    def test_recurring_event_requires_zone_and_preserves_dst_rule(self):
        args={'title':'Gym','start':'2026-10-30T09:00:00-07:00','end':'2026-10-30T10:00:00-07:00','recurrence':['RRULE:FREQ=WEEKLY;BYDAY=FR']}
        with self.assertRaisesRegex(ToolError,'time_zone'): calendar.fields(args)
        result=calendar.fields({**args,'time_zone':'America/Los_Angeles'})
        self.assertEqual(result['start']['timeZone'],'America/Los_Angeles')
        self.assertEqual(result['recurrence'],args['recurrence'])

    def test_all_day_dates_are_exclusive_and_cannot_mix_types(self):
        result=calendar.fields({'start':'2026-09-08','end':'2026-09-09','all_day':True})
        self.assertEqual(result['end'],{'date':'2026-09-09'})
        with self.assertRaises(ToolError): calendar.fields({'start':'2026-09-08','end':'2026-09-08','all_day':True})
        with self.assertRaises(ToolError): calendar.fields({'start':'2026-09-08','all_day':True}, {'end':{'dateTime':'2026-09-09T00:00:00Z'}})

    def test_update_uses_current_etag_and_preserves_unspecified_fields(self):
        current={'id':'event','etag':'v1','description':'Keep me','start':{'dateTime':'2026-09-08T09:00:00Z'},'end':{'dateTime':'2026-09-08T10:00:00Z'}}
        args={'event_id':'event','etag':'v1','scope':'occurrence','changes':{'title':'New title'}}
        with patch.object(google,'_get',return_value=current),patch.object(google,'_request',return_value={}) as request:
            calendar.update(args)
            self.assertEqual(request.call_args.kwargs['body'],{'summary':'New title'})
            self.assertEqual(request.call_args.kwargs['headers'],{'If-Match':'v1'})
            with self.assertRaisesRegex(ToolError,'changed'): calendar.update({**args,'etag':'old'})
            self.assertEqual(request.call_count,1)

    def test_series_and_occurrence_cannot_be_confused(self):
        parent={'id':'series','etag':'parent','recurrence':['RRULE:FREQ=DAILY']}
        with patch.object(google,'_get',return_value=parent),patch.object(google,'_request') as request:
            with self.assertRaisesRegex(ToolError,'whole series'):
                calendar.delete({'event_id':'series','etag':'parent','scope':'occurrence'})
            request.assert_not_called()
        occurrence={'id':'instance','etag':'instance-tag','recurringEventId':'series'}
        with patch.object(google,'_get',side_effect=[occurrence,parent]),patch.object(google,'_request',return_value={}) as request:
            calendar.delete({'event_id':'instance','etag':'parent','scope':'series'})
            self.assertTrue(request.call_args.args[1].endswith('/series'))
            self.assertEqual(request.call_args.kwargs['headers'],{'If-Match':'parent'})

    def test_delete_handles_empty_response_and_conflicts_are_not_success(self):
        credentials=Mock(valid=True)
        with patch.object(google,'_credentials',return_value=credentials),patch.object(google,'AuthorizedSession') as session:
            response=session.return_value.__enter__.return_value.request.return_value
            response.status_code=204
            self.assertEqual(google._request('DELETE','calendar/v3/calendars/primary/events/one'),{})
            response.json.assert_not_called()
            response.status_code=412
            with self.assertRaisesRegex(ToolError,'changed'): google._request('PATCH','calendar/v3/calendars/primary/events/one')

    def test_retry_checks_guests_and_recurrence_not_just_title(self):
        body={'id':'stable','summary':'Gym','attendees':[{'email':'new@example.com'}],'recurrence':['RRULE:FREQ=WEEKLY']}
        credentials=Mock(valid=True)
        with patch.object(google,'_credentials',return_value=credentials),patch.object(google,'AuthorizedSession') as session,patch.object(google,'_get',return_value={**body,'attendees':[{'email':'old@example.com'}]}):
            session.return_value.__enter__.return_value.request.return_value.status_code=409
            with self.assertRaisesRegex(ToolError,'changed'): google._request('POST','calendar/v3/calendars/primary/events',body=body)

    async def test_tools_reject_ambiguous_delete_and_unknown_fields(self):
        specs={s.name:s for s in read_specs()}
        with patch.object(google,'_request') as request:
            _,failed=await run(specs['google_calendar_delete_event'],{'event_id':'series','etag':'v1'})
            self.assertTrue(failed)
            _,failed=await run(specs['google_calendar_update_event'],{'event_id':'series','etag':'v1','scope':'series','changes':{'arbitrary':'field'}})
            self.assertTrue(failed)
            request.assert_not_called()
