#!/usr/bin/env bash
# Runs the brain (Python, :8000) and the audio gateway (Node, :8787) together.
# Ctrl+C stops both.   Usage: cd backend && ./scripts/dev.sh
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -x .venv/bin/python ]; then
  python3 -m venv .venv
  .venv/bin/python -m pip install -q -r requirements-dev.txt
fi
[ -d node_modules ] || npm install --silent

trap 'kill 0' EXIT
.venv/bin/python -m uvicorn app.main:app --reload --host 0.0.0.0 --port 8000 &
npx tsx watch src/index.ts &
wait
