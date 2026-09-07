# Personal assistant

A personal assistant built around a shared knowledge map. The map is a Postgres schema on Supabase that every agent on every device reads and writes: facts as time-bounded assertions with full transition history, relationships between entities, an append-only log of everything that happened, and the plans, rules and questions that drive a short spoken check-in every morning.

## Layout

```
assistant.py           talk, morning, snapshot, status
engine/                the conversation engine: map access, tools, context, runtimes
prompts/               the persona and the morning instructions
supabase/migrations/   the schema, in SQL
supabase/tests/        behavioral checks for the schema
eval/                  knowledge-update and abstention cases
scripts/                test.sh runs the suite, testdb.sh keeps a local test map, push.sh pushes migrations
docs/knowledge-map.md  how the map works
docs/engine.md         how the engine works
docs/research/         the research the design rests on
docs/design-v0.1.md    the original design doc
```

## Running it

```bash
pip3 install -r requirements.txt
export ASSISTANT_DATABASE_URL='postgresql://...'   # the project's session pooler URI
python3 assistant.py talk
```

For anything exploratory, use the test map instead of the real one:

```bash
scripts/testdb.sh up                                # a local Postgres with the migrations applied
export ASSISTANT_TEST_DATABASE_URL="$(scripts/testdb.sh url)"
python3 assistant.py talk --test
```

`docs/engine.md` covers the rest.

## The map

`docs/knowledge-map.md` explains the schema. To prove a change before pushing it:

```bash
scripts/test.sh
```

To push migrations to the project:

```bash
supabase link --project-ref koauvyfxewczcajnlrfp
supabase db push
```

## The eval set

`eval/cases.json` holds knowledge-update and abstention cases: what was said or synced, the question, the answer the assistant must give, and what the current views must show. It is the regression check for extraction, retrieval and consolidation, written before any of that logic exists so the logic is held to it rather than the other way round.

## Mac app

```bash
scripts/build-mac.sh
open "build/Personal Assistant.app"
```

The build uses `python3`; set `PYTHON` if your dependencies are in a different interpreter. The app runs the engine from this checkout, so keep the folder in place. It reads literal `export ASSISTANT_DATABASE_URL=...` and `ASSISTANT_TEST_DATABASE_URL=...` lines from `~/.zshrc` when launched from Finder. It never executes that file. Test mode defaults to the local database created by `scripts/testdb.sh up` if no test URL is set.

The window is one conversation with day markers rather than separate chats, a panel on the right with the day's plan, and a bar to type or talk. The model and the memory environment live behind the gear; there is no new-conversation button because there is only ever one conversation. The app connects automatically when opened and remembers your selected model and memory environment. Choosing Claude or ChatGPT, or switching test memory, reconnects automatically. Both models use the same shared transcript and knowledge map. Replies use the current conversation immediately; a smaller model saves structured memory in the background, with its progress shown separately. Speech models preload when the app opens and stay warm between voice conversations; preloading does not activate the microphone. Talk opens a compact floating voice panel with live captions and both sides of the conversation. The rest of the chat stays interactive. The microphone stays on during replies; speaking interrupts playback and generation. End stops voice mode. Switching to another app or minimizing this window also stops voice, so the microphone does not remain active in the background. Allow Microphone when macOS asks. Speech is transcribed locally through sherpa-onnx: a fast Zipformer supplies live words and Kroko corrects them during speech, then verifies the completed utterance; it never goes to Apple's speech service. The build downloads pinned recognition and speech models once. Your words appear in a fixed live-transcription panel as you speak. Kokoro's Michael voice generates American English locally at 1.1× speed, played through an echo-cancelled audio engine. Each sentence finishes generating before playback so it cannot stall between model chunks; following sentences generate while playback continues. A one-second silence threshold leaves room for pauses within an utterance; model buffering adds some delay before submission. Actual interruption timing depends on speech recognition and your audio devices. Local unsigned development builds may require renewed macOS permission after rebuilding.

ChatGPT uses your Codex subscription login through the official app server. Sign in with `codex login` if needed. API-key accounts are rejected. `ASSISTANT_OPENAI_MODEL` optionally selects a model; otherwise Codex chooses its default. Claude uses the existing Claude login and rejects API billing environment variables. Reported SDK dollar estimates are not invoices or proof of subscription charges.

Recognition uses [Kroko's community model](https://huggingface.co/Banafo/Kroko-ASR) under CC-BY-SA. Synthesis uses [Kokoro](https://k2-fsa.github.io/sherpa/onnx/tts/pretrained_models/kokoro.html). Both run locally without a speech API. Run `python3 -m scripts.check_voice` and `python3 -m scripts.check_synthesis` to test recorded audio and interruption without opening the microphone.

The experimental American Lower CSM adapter remains available through `python -m engine.voice.synthesize --american-lower` in the environment installed from `requirements-voice-mac.txt`; install its assets with `python -m engine.voice.csm_models`. It requires Apple Silicon and macOS 15 or later, uses about 9 GB of model memory, and generates slower than playback on this Mac. Its reference is from [Expresso](https://speechbot.github.io/expresso/) (Nguyen et al., Meta), distributed through [Kyutai's voice collection](https://huggingface.co/kyutai/tts-voices) under CC BY-NC 4.0, with generated playback lowered by 0.75 semitone. It is retained for noncommercial experiments, not used by the app.

For terminal ChatGPT conversations:

```bash
ASSISTANT_RUNTIME=codex python3 assistant.py talk
```

The assistant’s name lives in `identity.json`. Both model adapters use it through the shared persona in `prompts/persona.md`, and the Mac build copies it into the app. To rename the character, edit that one value and rebuild the app; storage paths and conversation history do not change.
