#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PYTHON="${PYTHON:-python3}"
PYTHON="$($PYTHON -c 'import sys; print(sys.executable)')"
(cd "$ROOT" && "$PYTHON" -m engine.voice.models && "$PYTHON" -m engine.voice.final_models)
VOICE_PYTHON="$PYTHON"
(cd "$ROOT" && "$VOICE_PYTHON" -m engine.voice.tts_models)
APP="$ROOT/build/Personal Assistant.app"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources" "$ROOT/build/icon.iconset"
swift "$ROOT/scripts/make_icon.swift" "$ROOT/build/icon.iconset"
iconutil -c icns "$ROOT/build/icon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
swiftc -parse-as-library "$ROOT/desktop/PersonalAssistant.swift" "$ROOT/desktop/OutputStream.swift" "$ROOT/desktop/LiveVoice.swift" "$ROOT/desktop/LocalSpeech.swift" "$ROOT/desktop/LocalVoice.swift" "$ROOT/desktop/VoiceTurn.swift" -o "$APP/Contents/MacOS/PersonalAssistant" -framework SwiftUI -framework AVFoundation
"$PYTHON" - "$APP" "$ROOT" "$PYTHON" "$VOICE_PYTHON" <<'PY'
import plistlib,sys,pathlib
app,root,python,voice_python=sys.argv[1:]
info={'CFBundleExecutable':'PersonalAssistant','CFBundleIdentifier':'com.carterwatts.personal-assistant','CFBundleName':'Personal Assistant','CFBundlePackageType':'APPL','CFBundleVersion':'1','CFBundleShortVersionString':'0.1','LSMinimumSystemVersion':'13.0','CFBundleIconFile':'AppIcon','NSMicrophoneUsageDescription':'Talk to your personal assistant.','AssistantRoot':root,'AssistantPython':python,'AssistantVoicePython':voice_python}
with open(pathlib.Path(app)/'Contents/Info.plist','wb') as f: plistlib.dump(info,f)
PY
codesign --force --deep --sign - "$APP"
printf 'Built %s\n' "$APP"
