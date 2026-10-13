#!/usr/bin/env bash
# Lab 03 validation — the green/red signal for your pull request.
#
# Gateway-free: it only reads the project files on disk, so it runs in a second
# with no Ignition gateway, no Docker, nothing but Python 3. It mirrors the
# "Validation passes locally" checkbox in the PR template.
#
# Checks:
#   1. every *.json under projects/ is valid JSON
#   2. every code.py under projects/ parses as Python 3
#
# Note: Ignition runs Jython 2.7, but this is a fast syntax sanity check, not a
# Jython validator. Write Python-3-parseable syntax (the lab's scripts already
# are); Jython-2-only constructs like `print "x"` would report a false failure.
#
# Exit code is 0 when everything is valid, 1 otherwise.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

command -v python3 >/dev/null 2>&1 || {
  echo "Error: python3 is required." >&2
  exit 1
}

fail=0

echo "→ Validating JSON resources under projects/ ..."
while IFS= read -r f; do
  if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$f" 2>/dev/null; then
    echo "  ✗ invalid JSON: $f"
    fail=1
  fi
done < <(find projects -name '*.json')

echo "→ Validating Python scripts under projects/ ..."
while IFS= read -r f; do
  if ! python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$f" 2>/dev/null; then
    echo "  ✗ syntax error (must be Python 3-parseable): $f"
    fail=1
  fi
done < <(find projects -name 'code.py')

if [ "$fail" -ne 0 ]; then
  echo "✗ validation failed"
  exit 1
fi

echo "✓ all project files valid"
# audit
