#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")"

echo "Building wakespike..."
xcrun swiftc -O \
  -framework CoreAudio \
  -framework Cocoa \
  -o wakespike \
  main.swift

echo "Built: $(pwd)/wakespike"
