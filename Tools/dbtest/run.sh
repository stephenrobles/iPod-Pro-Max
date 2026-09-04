#!/bin/zsh
# Builds and runs the dbtest harness against a simulated iPod folder.
set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/iPod Pro Max"
OUT="${TMPDIR:-/tmp}/dbtest"
mkdir -p "$OUT"
xcrun swiftc -O -target arm64-apple-macos15.0 -parse-as-library -o "$OUT/dbtest" \
  "$SRC"/Core/*.swift "$SRC"/Device/*.swift "$SRC"/Library/*.swift "$SRC"/Sync/*.swift "$ROOT/Tools/dbtest/main.swift"
"$OUT/dbtest" "$@"
