#!/usr/bin/env bash
# One-shot setup for the Lab 03 gateway:
#   - sanity-checks the host (docker + compose v2)
#   - sets the repo-wide git config (pre-commit dispatcher, diff driver)
#   - ensures .env is in place (copies from .env.example)
#   - brings up the single Ignition gateway
#   - waits for it to report RUNNING
#
# Re-run safely — every step is idempotent.

set -euo pipefail


PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

# ---- Host preflight (WSL/permissions) --------------------------------------
# Refuses a sudo'd run, verifies the repo is not on the Windows filesystem
# (/mnt/c), reclaims root-owned leftovers, and exports LAB_GID so the
# gateway container writes files this user can still edit. See
# scripts/preflight.sh and docs/wsl-setup.md.
# shellcheck source=preflight.sh disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preflight.sh"
lab_preflight

# ---- Repo-wide git config (hooks dispatcher + resource.json diff driver) ----
# One script at the repo root owns this for every lab; re-running is harmless.
"$(git -C "$PROJECT_ROOT" rev-parse --show-toplevel)/scripts/install-git-config.sh"

GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; RED=$'\033[0;31m'; NC=$'\033[0m'
[ -n "${NO_COLOR:-}" ] && { GREEN=""; YELLOW=""; RED=""; NC=""; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "${RED}Error: '$1' is required but not installed.${NC}" >&2
    exit 1
  }
}

require_cmd docker
require_cmd curl

if ! docker compose version >/dev/null 2>&1; then
  echo "${RED}Error: the Docker Compose V2 plugin is required (try 'docker compose version').${NC}" >&2
  exit 1
fi

# ---- .env -----------------------------------------------------------------
if [ ! -f .env ]; then
  echo "${YELLOW}.env not found — copying from .env.example.${NC}"
  cp .env.example .env
fi
# Record LAB_GID in the fresh .env so a later manual `docker compose up -d`
# (fresh terminal, no export) keeps the gateway in your group. See preflight.sh.
pf_persist_lab_gid

# ---- start ----------------------------------------------------------------
echo "${GREEN}Starting the Ignition gateway...${NC}"
docker compose up -d
echo ""

# ---- wait -----------------------------------------------------------------
# Same host port the compose file publishes (GATEWAY_PORT in .env, default 8088).
# An exported GATEWAY_PORT wins over .env, exactly like it does for compose.
GATEWAY_PORT="${GATEWAY_PORT:-$(grep -E '^GATEWAY_PORT=' .env 2>/dev/null | tail -n1 | cut -d= -f2- || true)}"
URL="http://localhost:${GATEWAY_PORT:-8088}"
echo "${GREEN}Waiting for the gateway at $URL to become RUNNING (cold start is slow)...${NC}"
attempts=0
max_attempts=120   # ~4 minutes
while [ $attempts -lt $max_attempts ]; do
  if curl -fsS "$URL/StatusPing" 2>/dev/null | grep -q RUNNING; then
    echo ""
    echo "${GREEN}Gateway RUNNING.${NC}"
    break
  fi
  attempts=$((attempts + 1))
  sleep 2
  printf '.'
done

if [ $attempts -ge $max_attempts ]; then
  echo ""
  echo "${RED}Error: gateway did not reach RUNNING within $((max_attempts * 2))s.${NC}" >&2
  echo "  Check logs:  docker logs --tail 200 lab03-ignition" >&2
  exit 1
fi

# ---- done -----------------------------------------------------------------
USER_VAL="$(grep -E '^GATEWAY_ADMIN_USERNAME=' .env | cut -d= -f2-)"
PASS_VAL="$(grep -E '^GATEWAY_ADMIN_PASSWORD=' .env | cut -d= -f2-)"
echo ""
echo "${GREEN}Setup complete!${NC}"
echo "  Gateway:  $URL"
echo "  Login:    user=${USER_VAL:-admin}  pass=${PASS_VAL:-password}"
echo "  Project:  'lab-project' (open Perspective at $URL/data/perspective/client/lab-project)"
echo ""
echo "Useful commands:"
echo "  docker compose ps                 # container state"
echo "  docker logs -f lab03-ignition     # tail gateway logs"
echo "  scripts/validate.sh               # validate project files (the PR check)"
echo "  docker compose restart        # reload project files after an edit"
echo "  scripts/scan.sh                   # faster reload via scan API (needs an API key)"
echo "  scripts/teardown.sh               # stop the gateway"
echo "  scripts/teardown.sh --volumes     # stop and wipe gateway state"
