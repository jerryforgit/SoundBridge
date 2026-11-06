#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
xcrun swiftc -O -framework CoreAudio -o audiodefault audiodefault.swift
echo "Built: $(pwd)/audiodefault"
