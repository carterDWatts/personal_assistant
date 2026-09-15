-- Ordinary replies belong in the conversation, without a push notification.
drop trigger queue_reply on assistant.events;
update assistant.reply_deliveries set cancelled_at=now() where sent_at is null and cancelled_at is null;
