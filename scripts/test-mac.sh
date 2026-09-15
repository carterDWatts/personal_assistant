#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/build"

check() {
  local name="$1"
  shift
  swiftc -parse-as-library "$@" "$ROOT/tst/swift/$name.swift" -o "$ROOT/build/$name"
  "$ROOT/build/$name"
}

check ChatScrollCheck "$ROOT/shared/ChatScrollView.swift" -framework SwiftUI
check OutputStreamCheck "$ROOT/desktop/OutputStream.swift"
check VoiceTurnCheck "$ROOT/desktop/VoiceTurn.swift"
check ReplyStateCheck "$ROOT/ios/Assistant/ReplyState.swift"
check SpotifyCheck "$ROOT/shared/SpotifyCommand.swift"
check LocalVoiceCheck "$ROOT/desktop/LocalVoice.swift" "$ROOT/desktop/OutputStream.swift" -framework AVFoundation
check MeetingCheck "$ROOT/shared/MeetingLibrary.swift"
check MeetingMediaCheck "$ROOT/shared/MeetingMedia.swift" -framework AVFoundation
check ComposerInputCheck "$ROOT/desktop/ComposerInput.swift" "$ROOT/shared/ChatImages.swift" -framework SwiftUI
check ChatCheck "$ROOT/shared/MeetingLibrary.swift" "$ROOT/shared/MeetingCapture.swift" "$ROOT/shared/MeetingBackground.swift" "$ROOT/shared/MeetingMedia.swift" -framework Speech "$ROOT/shared/PlanNotes.swift" "$ROOT/shared/ChatImages.swift" "$ROOT/desktop/Chat.swift" "$ROOT/desktop/EngineConnection.swift" \
  "$ROOT/desktop/OutputStream.swift" "$ROOT/desktop/LiveVoice.swift" \
  "$ROOT/desktop/LocalSpeech.swift" "$ROOT/desktop/LocalVoice.swift" \
  "$ROOT/desktop/VoiceTurn.swift" -framework AVFoundation
