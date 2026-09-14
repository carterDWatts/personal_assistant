# Recorded conversations

On iPhone, choose **Record or import conversation** from the conversation menu.
Start **Record meeting**, then close the panel to keep typing to Bunny Man. The
recording strip stays visible and has a Stop button. Voice chat is unavailable
while the meeting uses the microphone. This captures people speaking near the
phone, not audio from another app or a remote call.

The Mac waveform button opens the same transcript library for audio imports.
Both apps accept audio files supported by AVFoundation, including M4A, MP3, WAV
and CAF. Choose current knowledge or historical-only treatment before importing.

Audio stays in the app's local support directory. The transcript is checkpointed
locally, with stable section IDs and a durable upload queue. Closing the panel
leaves transcription running; quitting the app ends it. Recoverable text remains
on the device. Imports resume their memory uploads after reconnecting, without
creating a second copy of an acknowledged section.

Completed transcript sections are grouped roughly every 90 seconds during a
recording and at completion. They use the existing context-import queue and
subscription memory worker. Recording and transcription never wait for that
worker. The current question can carry up to 10,000 characters of recent transcript
as separate, quoted source context, without flooding the chat with transcript
messages. Turn retries must preserve the same context. Turning off **Use this
conversation in chat** removes this attachment; it does not erase saved memory.

Meeting imports are classified as external evidence in the same transaction that
creates their memory jobs. The extractor can record sourced facts, relationships,
and clarification questions, but cannot turn other people's speech into standing
rules, reminders, or direct actions. Speakers are not automatically identified.
Transcripts may need correction; retain the original audio when accuracy matters.

Transcription is local: Apple on-device English speech recognition on iPhone and
the installed Sherpa/Kroko models on Mac. Audio imports are split at speech pauses
with time offsets rather than relying on a single long recognition request.
Live recognition rotates requests while the original audio is continuously saved.
There is no new paid transcription service.

Tests cover long transcript ordering, revised partial results, bounded context,
crash recovery, duplicate-safe upload, external-source classification and turn
idempotency. `--meeting-replay` in a debug iPhone build transcribes a fixture from
Documents/meeting-replay.wav and writes Documents/meeting-result.json without
opening a chat, using the microphone or uploading to memory.
