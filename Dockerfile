FROM node:24.13.0-bookworm-slim AS codex
RUN npm install --global @openai/codex@0.153.4

FROM python:3.12.12-slim-bookworm
COPY deploy/supabase-ca.crt /usr/local/share/ca-certificates/supabase.crt
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg && rm -rf /var/lib/apt/lists/*
RUN update-ca-certificates
COPY --from=codex /usr/local/bin/node /usr/local/bin/node
COPY --from=codex /usr/local/lib/node_modules/@openai /usr/local/lib/node_modules/@openai
RUN ln -s /usr/local/lib/node_modules/@openai/codex/bin/codex.js /usr/local/bin/codex \
    && groupadd --gid 10001 assistant \
    && useradd --uid 10001 --gid 10001 --home-dir /data assistant
WORKDIR /app
COPY requirements-host.txt .
RUN pip install --no-cache-dir torch==2.14.0 --index-url https://download.pytorch.org/whl/cpu
RUN pip install --no-cache-dir -r requirements-host.txt
ENV HF_HOME=/opt/assistant-pocket
COPY engine/voice/catalog.py /tmp/voice_catalog.py
RUN PYTHONPATH=/tmp python -c "from pocket_tts import TTSModel; from voice_catalog import VOICES; m=TTSModel.load_model(language='english_2026-04',temp=.3); [m.get_state_for_audio_prompt(v['source']) for v in VOICES]" && rm /tmp/voice_catalog.py
COPY engine/voice/tts_models.py /tmp/install_voice.py
ENV ASSISTANT_VOICE_MODEL_DIR=/opt/assistant-voice
RUN python /tmp/install_voice.py && rm /tmp/install_voice.py
COPY engine ./engine
COPY prompts ./prompts
COPY identity.json .
COPY scripts/host-entry.py ./scripts/host-entry.py
ENV HOME=/data PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
CMD ["python", "scripts/host-entry.py"]
