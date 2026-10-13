#!/bin/bash
# Shared helpers for setup.sh / scan.sh / teardown.sh.
# Sourced, not executed: . "$(dirname "$0")/lib.sh"

# Colors and shared constants below are consumed by the scripts that source
# this file, so shellcheck cannot see their use from here.
# shellcheck disable=SC2034

# Guard against direct execution.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  echo "scripts/lib.sh is meant to be sourced, not executed." >&2
  exit 1
fi

# Idempotent — only initialize once.
if [ "${_LAB_LIB_LOADED:-0}" = "1" ]; then
  return 0
fi
_LAB_LIB_LOADED=1

# Repo + scripts dir (works regardless of caller's cwd).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors. Suppress when stdout isn't a terminal or NO_COLOR is set.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; NC=''
fi

# Names of the three gateways the lab ships with. Used for iteration in
# setup.sh and validation in scan.sh.
LAB_GATEWAYS=(local test production)

# Map a gateway name → its host port. Same variables (and defaults) as the
# port mappings in docker-compose.yaml: an exported value wins, then .env,
# then the default. Override them in .env when a port is taken on your host.
gateway_port() {
  local var def
  case "${1:-local}" in
    local)      var=GATEWAY_PORT;            def=8088 ;;
    test)       var=TEST_GATEWAY_PORT;       def=8089 ;;
    production) var=PRODUCTION_GATEWAY_PORT; def=8090 ;;
    *)          return 1 ;;
  esac
  local v="${!var:-}"
  [ -n "$v" ] || v="$(env_value "$var")"
  printf '%s' "${v:-$def}"
}

# Host port of the TimescaleDB sidecar (POSTGRES_PORT, default 5432).
postgres_port() {
  local v="${POSTGRES_PORT:-}"
  [ -n "$v" ] || v="$(env_value POSTGRES_PORT)"
  printf '%s' "${v:-5432}"
}

# Map a gateway name → its host-facing URL. For the LOCAL gateway an exported
# IGNITION_URL wins (the same override scan.sh honours); test and production
# always follow their port variable.
gateway_url() {
  local port
  port="$(gateway_port "${1:-local}")" || return 1
  if [ "${1:-local}" = "local" ] && [ -n "${IGNITION_URL:-}" ]; then
    printf '%s' "${IGNITION_URL%/}"
    return 0
  fi
  printf 'http://localhost:%s' "$port"
}

# Map a gateway name → its docker container name (the value of
# `container_name:` in docker-compose.yaml). Used by deploy workflows for
# `docker cp` and by setup.sh to print log hints.
gateway_container() {
  case "${1:-local}" in
    local) printf 'lab06-gateway-local-development' ;;
    test)   printf 'lab06-gateway-test' ;;
    production)  printf 'lab06-gateway-production' ;;
    *)     return 1 ;;
  esac
}

# Read a single KEY from a .env-style file (default: <repo>/.env).
# Strips optional single/double quotes around the value.
env_value() {
  local key="$1"
  local env_file="${2:-$PROJECT_ROOT/.env}"
  [ -f "$env_file" ] || { echo ""; return; }
  local v
  v="$(grep -E "^[[:space:]]*${key}=" "$env_file" | head -n1 | cut -d= -f2-)"
  v="${v%\"}"; v="${v#\"}"
  v="${v%\'}"; v="${v#\'}"
  printf '%s' "$v"
}

# Print the per-gateway API key from .env (empty if unset). Each gateway has
# its OWN key — scripts/generate-api-keys.sh generates them on setup; nothing
# key-related is committed.
api_key_for() {
  case "${1:-local}" in
    local)      env_value IGNITION_API_KEY_LOCAL ;;
    test)       env_value IGNITION_API_KEY_TEST ;;
    production) env_value IGNITION_API_KEY_PRODUCTION ;;
    *)          return 1 ;;
  esac
}

# Populate IGNITION_API_KEY from .env. Precedence (first non-empty wins):
#   1. IGNITION_API_KEY already set in the environment (CI sets this)
#   2. IGNITION_API_KEY_<GATEWAY> from .env (when $1 is local|test|production)
#   3. IGNITION_API_KEY from .env (legacy single-key shape)
load_api_key_from_env() {
  if [ -n "${IGNITION_API_KEY:-}" ]; then
    return 0
  fi
  local gateway="${1:-}"
  if [ -n "$gateway" ]; then
    local per_gw
    case "$gateway" in
      local|test|production) per_gw="$(api_key_for "$gateway")" ;;
    esac
    if [ -n "${per_gw:-}" ]; then
      IGNITION_API_KEY="$per_gw"
      export IGNITION_API_KEY
      return 0
    fi
  fi
  IGNITION_API_KEY="$(env_value IGNITION_API_KEY)"
  export IGNITION_API_KEY
}

# Returns 0 if IGNITION_API_KEY is empty or an obvious placeholder. Keys are
# generated into .env by scripts/generate-api-keys.sh (run from setup.sh), so
# this only triggers when setup has not run yet.
is_placeholder_api_key() {
  case "${IGNITION_API_KEY:-}" in
    ''|*replace-me*) return 0 ;;
    *) return 1 ;;
  esac
}
