#!/bin/zsh
# Build, copy to ~/Applications, and register the login item.
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
"$PROJECT_DIR/scripts/build-app.sh"
mkdir -p ~/Applications ~/Library/LaunchAgents
rm -rf ~/Applications/"Token Usage Widget.app"
cp -R "$PROJECT_DIR/dist/Token Usage Widget.app" ~/Applications/
PLIST=~/Library/LaunchAgents/com.zaynhuang.token-usage-widget.plist
sed "s|__HOME__|$HOME|g" "$PROJECT_DIR/Resources/com.zaynhuang.token-usage-widget.plist" > "$PLIST"
launchctl bootout "gui/$(id -u)/com.zaynhuang.token-usage-widget" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Installed. Look for the bar-chart icon in the menu bar."
