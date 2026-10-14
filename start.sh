#!/bin/bash
# HOPE Dome Sim – simple start without Syphon (macOS / Linux).
# Serves this folder on http://localhost:8765 and opens it in your browser.
cd "$(dirname "$0")"
PORT=8765
URL="http://localhost:$PORT/index.html"
if ! command -v python3 >/dev/null 2>&1; then echo "python3 not found. Install Python 3 or open index.html directly in Chrome."; exit 1; fi
( sleep 1
  if command -v open >/dev/null 2>&1; then open "$URL"
  elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$URL"
  else echo "Open $URL in your browser"; fi ) &
echo "HOPE Dome Sim → $URL   (Ctrl+C to stop)"
exec python3 -m http.server "$PORT" --bind 127.0.0.1
