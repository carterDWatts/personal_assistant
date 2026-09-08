#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -z "${PYTHON:-}" ]]; then
  for candidate in "$ROOT/.venv/bin/python3" "$HOME/.pyenv/shims/python3" "$(command -v python3)"; do
    if [[ -x "$candidate" ]] && "$candidate" -c 'import psycopg, sherpa_onnx, numpy, jsonschema' 2>/dev/null; then
      PYTHON="$candidate"
      break
    fi
  done
fi
: "${PYTHON:?Set PYTHON to an interpreter with the app requirements installed}"
"$PYTHON" -c 'import psycopg, sherpa_onnx, numpy, jsonschema' 
PYTHON="$($PYTHON -c 'import sys; print(sys.executable)')"
(cd "$ROOT" && "$PYTHON" -m engine.voice.models && "$PYTHON" -m engine.voice.final_models)
VOICE_PYTHON="$PYTHON"
(cd "$ROOT" && "$VOICE_PYTHON" -m engine.voice.tts_models)
APP="$ROOT/build/Personal Assistant.app"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources" "$ROOT/build/icon.iconset"
swiftc -parse-as-library "$ROOT/scripts/make_icon.swift" "$ROOT/shared/BunnyGlyph.swift" -o "$ROOT/build/make-icon" -framework SwiftUI
"$ROOT/build/make-icon" "$ROOT/build/icon.iconset" "$ROOT/desktop/Assets/AppIcon.png"
cp "$ROOT/identity.json" "$APP/Contents/Resources/identity.json"
cp "$ROOT/desktop/Assets/FlowerBed.png" "$APP/Contents/Resources/FlowerBed.png"
iconutil -c icns "$ROOT/build/icon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
swiftc -parse-as-library "$ROOT/desktop/PersonalAssistant.swift" "$ROOT/shared/ContextImport.swift" "$ROOT/shared/BunnyGlyph.swift" "$ROOT/desktop/BunnyArtwork.swift" "$ROOT/desktop/OutputStream.swift" "$ROOT/desktop/LiveVoice.swift" "$ROOT/desktop/LocalSpeech.swift" "$ROOT/desktop/LocalVoice.swift" "$ROOT/desktop/VoiceTurn.swift" -o "$APP/Contents/MacOS/PersonalAssistant" -framework SwiftUI -framework AVFoundation
"$PYTHON" - "$APP" "$ROOT" "$PYTHON" "$VOICE_PYTHON" <<'PY'
import json,plistlib,sys,pathlib
app,root,python,voice_python=sys.argv[1:]
name=json.loads((pathlib.Path(root)/'identity.json').read_text())['name']
info={'CFBundleExecutable':'PersonalAssistant','CFBundleIdentifier':'com.carterwatts.personal-assistant','CFBundleName':name,'CFBundleDisplayName':name,'CFBundlePackageType':'APPL','CFBundleVersion':'1','CFBundleShortVersionString':'0.1','LSMinimumSystemVersion':'13.0','CFBundleIconFile':'AppIcon','NSMicrophoneUsageDescription':'Talk to your personal assistant.','AssistantRoot':root,'AssistantPython':python,'AssistantVoicePython':voice_python}
with open(pathlib.Path(app)/'Contents/Info.plist','wb') as f: plistlib.dump(info,f)
PY
codesign --force --deep --sign - "$APP"
printf 'Built %s\n' "$APP"
