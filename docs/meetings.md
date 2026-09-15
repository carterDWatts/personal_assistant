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
subscription memory worker. Each batch carries its recording ID and position, so
extraction can read neighboring speech and reuse entities already found in that
recording. Batch IDs remain stable across retries. Older uploads without these
fields still work, but are not automatically regrouped.

The worker starts with a bounded excerpt of relevant facts and relationships,
then pages through the map or recording when it needs more. Explicit user rules
stay in its stable instructions. A read budget bounds each extraction attempt;
uncommitted work stays queued for retry. There is no change to transcript retention.

Job receipts retain the proposed operations, resolved arguments, returned record
IDs, and before/after state for fact and relationship assertions. Their effects
are marked created, confirmed, or changed; other operations are marked applied.
Job metrics include initial context characters, read calls, returned characters,
elapsed time, and runtime token usage. These distinguish a successful batch from
proof that all useful information was captured. Semantic extraction still needs
review against the source.

Recording and transcription never wait for that
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
