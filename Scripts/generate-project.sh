#!/usr/bin/env bash
set -euo pipefail

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "XcodeGen is required to generate keyboard.wtf.xcodeproj. Install it with: brew install xcodegen" >&2
  exit 1
fi

xcodegen generate --spec project.yml
