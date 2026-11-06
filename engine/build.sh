#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
xcrun swiftc -O -framework CoreAudio -framework Cocoa -framework AudioToolbox \
  -o engine Engine.swift DSP.swift EQ.swift SharedRing.swift MatrixReverbAU.swift main.swift
echo "Built: $(pwd)/engine"
