# Native alarms

An alarm is an explicit ringing delivery for a contextual reminder. It is never
inferred from severity alone. Ask for an alarm at an exact future time; the assistant
saves `alarm_at` on the reminder and the connected iPhone schedules it with AlarmKit.
iOS 26 or newer and the user's Alarms permission are required.

The phone reads `alarm_sync`, schedules through Apple's API, checks the returned
system state, and writes an authenticated `alarm_receipt` for that reminder revision.
The assistant reports readiness only from a current scheduled receipt. A closed or
offline phone cannot receive a new alarm immediately: it remains unconfirmed until
the app connects. Once scheduled, ringing belongs to iOS and needs no server call.

The reminder owns the title, context and time. Snoozing moves the alarm; completing,
cancelling or explicitly removing ringing cancels it when the phone next syncs.
Opening the alarm goes directly into the conversation about that reminder. Stopping
or dismissing it does not complete the task. Ordinary follow-up notifications keep
tracking unfinished work and never automatically rearm the native alarm.

Local identifiers and versions prevent duplicate scheduling on reconnect. A missed
alarm is not scheduled late. Permission denial, unsupported iOS and scheduling errors
remain visible in the app and in device receipts. Changes made elsewhere need the
phone to sync; do not treat an offline cancellation as already applied on that phone.

Tests cover version conflicts, device authorization, cancellation, snoozing, denied
permissions, repeat synchronization and failed receipts. The Xcode UI test schedules
a real AlarmKit alarm in the iPhone simulator, observes `.alerting`, then stops it.
The test screen is compiled only into debug builds.

[Apple's AlarmKit documentation](https://developer.apple.com/documentation/alarmkit)
