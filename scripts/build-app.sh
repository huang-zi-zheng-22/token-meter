#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
APP_DIR="$PROJECT_DIR/dist/Token Usage Widget.app"
CONTENTS_DIR="$APP_DIR/Contents"

mkdir -p "$PROJECT_DIR/.build/self-test"
swiftc -parse-as-library \
  "$PROJECT_DIR/Sources/TokenUsageWidget/UsageCollector.swift" \
  "$PROJECT_DIR/Sources/TokenUsageWidget/ClaudeUsageClient.swift" \
  "$PROJECT_DIR/Sources/TokenUsageWidget/DeepSeekBalanceClient.swift" \
  "$PROJECT_DIR/scripts/SelfTest.swift" \
  -o "$PROJECT_DIR/.build/self-test/TokenUsageWidgetSelfTest"
"$PROJECT_DIR/.build/self-test/TokenUsageWidgetSelfTest"
swift build -c release --package-path "$PROJECT_DIR"

mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
cp "$PROJECT_DIR/.build/release/TokenUsageWidget" "$CONTENTS_DIR/MacOS/TokenUsageWidget"
cp "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
chmod 755 "$CONTENTS_DIR/MacOS/TokenUsageWidget"
codesign --force --deep --sign - "$APP_DIR"

echo "$APP_DIR"
