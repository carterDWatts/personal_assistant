"""External data tools shared by all assistant runtimes."""


def read_specs():
    from engine.integrations.discovery import specs as discovery_specs
    from engine.integrations.web import specs as web_specs
    from engine.integrations.news import specs as news_specs
    from engine.tools import ToolSpec
    from engine.integrations.calendar import specs as calendar_specs, changes, notify, obj, string
    from engine.integrations.weather import forecast
    from engine.integrations.google import calendar_events, calendar_create_event, mail_search, mail_read
    from engine.integrations.workspace import specs
    from engine.integrations.services import specs as service_specs
    return discovery_specs() + web_specs() + news_specs() + specs() + service_specs() + calendar_specs() + [ToolSpec("weather_forecast",
        "Get current weather estimates, hourly rain and wind for the next 24 hours, and a seven-day forecast. "
        "Use whenever weather matters to a question or plan. Supply the city and state/country from the conversation or memory. "
        "Returns the resolved location, units and freshness; requires no account.",
        {"type": "object", "properties": {
            "location": {"type": "string", "minLength": 2, "maxLength": 160},
            "units": {"type": "string", "enum": ["us", "metric"]}},
         "required": ["location"], "additionalProperties": False}, forecast),
        ToolSpec("google_calendar_events", "Read upcoming events from the connected Google account’s selected calendars. Fetch before advising about availability.",
            {"type": "object", "properties": {"days": {"type": "integer", "minimum": 1, "maximum": 14}}, "additionalProperties": False}, calendar_events),
        ToolSpec("google_calendar_create_event", "Create calendar events when requested, including recurring, all-day and invited events. Read availability first. Timed start/end need UTC offsets; repeating timed events also need an IANA time_zone. Recurrence uses RRULE/RDATE/EXDATE; all-day end dates are exclusive. Guests require the user's request and are notified by default. Identical requests reuse the event ID after uncertain responses.",
            obj({**changes,'calendar_id':string,'send_updates':notify},['title','start','end']), calendar_create_event),
        ToolSpec("google_mail_search", "Search current Gmail excerpts, including sent mail. Uses Gmail search syntax; defaults to the last day. Read only; cannot send or modify mail. Excerpts may omit details, so never claim to have read the complete message.",
            {"type": "object", "properties": {"query": {"type": "string", "maxLength": 500}}, "additionalProperties": False}, mail_search),
        ToolSpec("google_mail_read", "Read an email’s text before acting on its details. Use a message ID returned by google_mail_search. Attachments are excluded; long messages are marked truncated.",
            {"type": "object", "properties": {"message_id": {"type": "string", "pattern": "^[a-fA-F0-9]+$", "maxLength": 64}},
             "required": ["message_id"], "additionalProperties": False}, mail_read)]
