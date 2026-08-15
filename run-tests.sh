#!/bin/bash
# Прогоняет тесты логики автоисправления и словарей.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

# Swift разрешает код верхнего уровня только в файле main.swift
cp "$DIR/tests.swift" "$OUT/main.swift"
swiftc -O -framework Cocoa -framework Carbon "$DIR/Core.swift" "$OUT/main.swift" -o "$OUT/tests"
"$OUT/tests"
