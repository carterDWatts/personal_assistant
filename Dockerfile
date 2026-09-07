FROM node:24.13.0-bookworm-slim AS codex
RUN npm install --global @openai/codex@0.153.4

FROM python:3.12.12-slim-bookworm
COPY deploy/supabase-ca.crt /usr/local/share/ca-certificates/supabase.crt
RUN update-ca-certificates
COPY --from=codex /usr/local/bin/node /usr/local/bin/node
COPY --from=codex /usr/local/lib/node_modules/@openai /usr/local/lib/node_modules/@openai
RUN ln -s /usr/local/lib/node_modules/@openai/codex/bin/codex.js /usr/local/bin/codex \
    && groupadd --gid 10001 assistant \
    && useradd --uid 10001 --gid 10001 --home-dir /data assistant
WORKDIR /app
COPY requirements-host.txt .
RUN pip install --no-cache-dir -r requirements-host.txt
COPY engine ./engine
COPY prompts ./prompts
COPY identity.json .
COPY scripts/host-entry.py ./scripts/host-entry.py
ENV HOME=/data PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
CMD ["python", "scripts/host-entry.py"]
