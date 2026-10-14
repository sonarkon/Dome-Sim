#!/bin/bash
# HOPE Dome Sim – double-click start: builds the Syphon bridge if needed and runs it. (Sonarkon – https://github.com/sonarkon/Dome-Sim)
cd "$(dirname "$0")"
if [ ! -x ./syphon-bridge ] || [ syphon-bridge.m -nt ./syphon-bridge ]; then
  ./build.sh || { echo "Build failed (install the Xcode Command Line Tools: xcode-select --install)"; read -r; exit 1; }
fi
open "http://localhost:8766" 2>/dev/null &
exec ./syphon-bridge --root ..
