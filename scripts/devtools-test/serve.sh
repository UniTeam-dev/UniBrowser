#!/bin/bash
# Serves the DevTools test page on two ports: the page on 8000 and its iframe on 8001
# (a different port is a different origin). Open http://127.0.0.1:8000. Ctrl+C stops both.
cd "$(dirname "$0")"
python3 -m http.server 8001 --bind 127.0.0.1 >/dev/null 2>&1 &
trap 'kill $!' EXIT
python3 -m http.server 8000 --bind 127.0.0.1
