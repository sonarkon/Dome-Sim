#!/bin/bash
# Builds the HOPE Dome Sim Syphon bridge (needs only the Xcode Command Line Tools)
set -e
cd "$(dirname "$0")"
clang -fobjc-arc -O2 -Wall -Wno-deprecated-declarations \
  -framework Foundation -framework Metal -framework CoreImage -framework ImageIO -framework CoreGraphics \
  syphon-bridge.m -o syphon-bridge
echo "OK: $(pwd)/syphon-bridge"
