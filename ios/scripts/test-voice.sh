#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
: "${DEVELOPER_DIR:=/Applications/Xcode-26.3.app/Contents/Developer}"
export DEVELOPER_DIR
DEVICE="${ASSISTANT_TEST_SIMULATOR:-94F91374-1E5B-4920-A105-D470E57D1663}"
RESULT="$ROOT/build/voice-$(date +%Y%m%d-%H%M%S).xcresult"
mkdir -p "$ROOT/build"
xcodebuild -project "$ROOT/ios/Assistant.xcodeproj" -scheme Assistant \
  -destination "id=$DEVICE" -derivedDataPath "$ROOT/build/ios-test" \
  -only-testing:AssistantUITests test
xcodebuild -project "$ROOT/ios/Assistant.xcodeproj" -scheme Assistant \
  -destination "id=$DEVICE" -derivedDataPath "$ROOT/build/ios-test" \
  -only-testing:AssistantTests -resultBundlePath "$RESULT" \
  "ASSISTANT_TEST_MODEL=${ASSISTANT_TEST_MODEL:-}" test
