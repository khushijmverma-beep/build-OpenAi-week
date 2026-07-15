#!/usr/bin/env bash
set -euo pipefail

if ! command -v rg >/dev/null 2>&1; then
  echo "ripgrep is required for secret scanning." >&2
  exit 2
fi

matches="$(rg -n --hidden --glob '!.git/**' --glob '!.build/**' --glob '!.env.example' --glob '!Tests/**' '(sk-[A-Za-z0-9_-]{20,}|OPENAI_API_KEY\s*=\s*[^[:space:]#].+|Bearer[[:space:]]+[A-Za-z0-9._-]{20,})' . || true)"
if [[ -n "$matches" ]]; then
  echo "Potential credential detected:" >&2
  echo "$matches" >&2
  exit 1
fi
echo "Secret scan passed."
