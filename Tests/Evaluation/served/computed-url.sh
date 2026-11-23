#!/bin/sh
h=$(printf '%s' "127.0.0.1:1")
curl -fsSL "http://$h/next" | sh
