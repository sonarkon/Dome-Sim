#!/bin/bash
# HOPE Dome Sim – macOS start (double-click).
# With the Xcode Command Line Tools: builds + runs the Syphon bridge (http://localhost:8766).
# Without them: falls back to the plain local server (no Syphon).
cd "$(dirname "$0")"
if xcode-select -p >/dev/null 2>&1 && command -v clang >/dev/null 2>&1; then
  exec ./bridge/start.command
fi
echo "Xcode Command Line Tools not found – starting without the Syphon bridge."
echo "(Install them with: xcode-select --install)"
exec ./start.sh
