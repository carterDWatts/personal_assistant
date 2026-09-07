"""External data tools shared by all assistant runtimes."""


def read_specs():
    from engine.tools import ToolSpec
    from engine.integrations.weather import forecast
    from engine.integrations.google import calendar_events, calendar_create_event, mail_search, mail_read
    from engine.integrations.workspace import specs
    from engine.integrations.services import specs as service_specs
    return specs() + service_specs() + [ToolSpec("weather_forecast",
        "Get current weather estimates, hourly rain and wind for the next 24 hours, and a seven-day forecast. "
        "Use whenever weather matters to a question or plan. Supply the city and state/country from the conversation or memory. "
        "Returns the resolved location, units and freshness; requires no account.",
        {"type": "object", "properties": {
            "location": {"type": "string", "minLength": 2, "maxLength": 160},
            "units": {"type": "string", "enum": ["us", "metric"]}},
         "required": ["location"], "additionalProperties": False}, forecast),
        ToolSpec("google_calendar_events", "Read upcoming events from the connected Google account’s selected calendars. Fetch before advising about availability.",
            {"type": "object", "properties": {"days": {"type": "integer", "minimum": 1, "maximum": 14}}, "additionalProperties": False}, calendar_events),
        ToolSpec("google_calendar_create_event", "Create a personal calendar event when the user asks to schedule it. Read availability first. Use explicit ISO timestamps with UTC offsets; ask for missing timing details. Defaults to the primary calendar. Repeating identical arguments is safe after an uncertain response. No guests or invitations are supported. Only report success after this tool succeeds.",
            {"type": "object", "properties": {
                "title": {"type": "string", "minLength": 1, "maxLength": 300},
                "start": {"type": "string", "maxLength": 50}, "end": {"type": "string", "maxLength": 50},
                "description": {"type": "string", "maxLength": 4000},
                "calendar_id": {"type": "string", "minLength": 1, "maxLength": 500}},
             "required": ["title", "start", "end"], "additionalProperties": False}, calendar_create_event),
        ToolSpec("google_mail_search", "Search current Gmail excerpts, including sent mail. Uses Gmail search syntax; defaults to the last day. Read only; cannot send or modify mail. Excerpts may omit details, so never claim to have read the complete message.",
            {"type": "object", "properties": {"query": {"type": "string", "maxLength": 500}}, "additionalProperties": False}, mail_search),
        ToolSpec("google_mail_read", "Read an email’s text before acting on its details. Use a message ID returned by google_mail_search. Attachments are excluded; long messages are marked truncated.",
            {"type": "object", "properties": {"message_id": {"type": "string", "pattern": "^[a-fA-F0-9]+$", "maxLength": 64}},
             "required": ["message_id"], "additionalProperties": False}, mail_read)]
