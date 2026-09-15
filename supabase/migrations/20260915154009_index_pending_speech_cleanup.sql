-- Only undelivered/retained audio needs expiry work; text and memory stay untouched.
create index events_pending_audio on assistant.events(created_at,cursor)
where payload->>'type'='speech' and payload ? 'url';
