#!/usr/bin/env bash
# Tell the gateway to scan project files AND gateway config, picking up changes
# you've made under projects/ — no restart needed. Run this after editing a
# view or a script. Two scans, two jobs: a project scan reloads views &
# scripts, a config scan reloads gateway config files.
#
# Why this exists: a running gateway does NOT auto-detect edits to the
# bind-mounted project files; you have to trigger a scan (or restart it).
#
# One-time setup: the scan API needs an API key whose security level has
# gateway write permission. In the gateway UI (http://localhost:8088, or your
# GATEWAY_PORT):
#   1. Platform → Security → Levels: add a custom level, e.g. "Scan"
#   2. Platform → Security → General Settings: add that level to
#      Gateway Write Permissions (the scan routes check write permission)
#   3. Platform → Security → API Keys → Create API Key: grant the "Scan" level, and
#      disable "Require secure connections for API Keys" (this lab's gateway
#      is plain http)
#   4. Copy the generated key — it has the form <name>:<secret> — into .env as:
#      IGNITION_API_KEY=<value>

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

# Load .env (gateway URL + API key) if present.
if [ -f .env ]; then
  set -a
  # .env is generated locally; there's nothing for shellcheck to follow.
  # shellcheck source=/dev/null
  . ./.env
  set +a
fi

URL="${IGNITION_URL:-http://localhost:${GATEWAY_PORT:-8088}}"
KEY="${IGNITION_API_KEY:-}"

if [ -z "$KEY" ]; then
  echo "No IGNITION_API_KEY set in .env — can't trigger a scan over the API."
  echo "Create one in the gateway UI ($URL) — see the one-time setup steps at the"
  echo "top of this script — then add it to .env as  IGNITION_API_KEY=<value>"
  echo "and re-run  scripts/scan.sh."
  echo "(Or just restart the gateway:  docker compose restart  — slower, no key needed.)"
  exit 1
fi

# One POST per scan type; the gateway queues a scan job for each.
scan() {
  curl -s -o /dev/null -w "%{http_code}" -X POST \
    -H "X-Ignition-API-Token: $KEY" \
    -H "Accept: application/json" \
    --max-time 30 \
    "$URL/data/api/v1/scan/$1" || echo 000
}

failed=0
for target in projects config; do
  code=$(scan "$target")
  if [ "$code" -ge 200 ] && [ "$code" -lt 300 ]; then
    echo "✓ ${target} scan triggered (HTTP $code)."
  else
    echo "✗ ${target} scan failed (HTTP $code)." >&2
    echo "  Check that IGNITION_API_KEY in .env is the full <name>:<secret> value and" >&2
    echo "  that its security level is in the gateway's write permissions (see header)." >&2
    failed=1
  fi
done

if [ "$failed" -ne 0 ]; then
  exit 1
fi
echo "The gateway now has your latest changes."
