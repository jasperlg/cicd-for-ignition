#!/bin/bash
# validate.sh: run the checks of .github/workflows/lab06-ci.yml (repo root)
# locally, before you open a PR.
#
# Always runs (only bash, git and python3 needed), the `validate` and
# `secret-scan` jobs:
#   1. Every *.json under projects/ and services/ parses.
#   2. .deployignore patterns are relative (no leading /).
#   3. Secret scan: no real files under secrets/, no known secret values in
#      the gateway payload (projects/ + services/). A full gitleaks history
#      scan is the lab's stretch S3; it runs in CI, not here.
#   4. security-properties doesn't name a throwaway temp_N identity.
# Runs when the tool is installed, the `lint` job (skipped with a hint
# otherwise; CI always runs them):
#   5. ign-lint on every Perspective view.json, with rule_config.json (run
#      from the repo root, like CI; pip install ign-lint==0.6.1).
#   6. yamllint, shellcheck and actionlint, as in CI.
#   7. docker compose config -q.
#
# Exits non-zero if any check fails. No running Ignition needed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
cd "$PROJECT_ROOT" || exit 1

rc=0

# 1. JSON validity sweep -------------------------------------------------------
echo "→ JSON validity sweep (projects/, services/)"
json_fail=0
while IFS= read -r f; do
  if ! python3 -m json.tool "$f" > /dev/null 2>&1; then
    echo -e "  ${RED}invalid JSON:${NC} $f"
    json_fail=1
  fi
done < <(find projects services -type f -name '*.json' 2>/dev/null)
if [ "$json_fail" -eq 0 ]; then
  echo -e "  ${GREEN}ok${NC} — all JSON parses"
else
  rc=1
fi

# 2. .deployignore syntax ------------------------------------------------------
echo "→ .deployignore syntax (patterns must be relative)"
if [ -f .deployignore ]; then
  di_fail=0
  n=0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    if [[ "$line" =~ ^/ ]]; then
      echo -e "  ${RED}line $n:${NC} pattern must be relative, not absolute: $line"
      di_fail=1
    fi
  done < .deployignore
  if [ "$di_fail" -eq 0 ]; then
    echo -e "  ${GREEN}ok${NC} — patterns look fine"
  else
    rc=1
  fi
else
  echo "  (no .deployignore — skipped)"
fi

# 3. Secret scan ---------------------------------------------------------------
echo "→ secret scan (secrets/ contents, payload values)"
ss_fail=0

# 3a. Only *.example files and the README may be TRACKED under secrets/.
bad_tracked="$(git ls-files 'secrets/' 2>/dev/null | grep -vE '\.example$|/README\.md$' || true)"
if [ -n "$bad_tracked" ]; then
  while IFS= read -r f; do
    echo -e "  ${RED}secret file committed:${NC} $f — rotate this credential, then remove the file"
  done <<< "$bad_tracked"
  ss_fail=1
fi

# 3b. Untracked real secret files are fine — but only when .gitignore actually
# covers them. A secrets/*.txt that git would pick up is one `git add .` away
# from a burned credential.
while IFS= read -r f; do
  case "$f" in *.example|*README.md) continue ;; esac
  if git ls-files --error-unmatch "$f" > /dev/null 2>&1; then
    continue # already reported by 3a
  fi
  if ! git check-ignore -q "$f" 2>/dev/null; then
    echo -e "  ${RED}not gitignored:${NC} $f — fix .gitignore before doing anything else"
    ss_fail=1
  fi
done < <(find secrets -type f 2>/dev/null)

# 3c. None of the lab's known secret values may appear in the gateway payload.
for ex in secrets/*.example; do
  [ -f "$ex" ] || continue
  value="$(cat "$ex")"
  [ -n "$value" ] || continue
  if hits="$(grep -rl -F "$value" projects/ services/ 2>/dev/null)"; then
    while IFS= read -r f; do
      echo -e "  ${RED}secret value from $ex found in:${NC} $f — use a referenced secret instead"
    done <<< "$hits"
    ss_fail=1
  fi
done

if [ "$ss_fail" -eq 0 ]; then
  echo -e "  ${GREEN}ok${NC} — no secrets where they shouldn't be"
else
  rc=1
fi

# 4. identity policy -----------------------------------------------------------
# security-properties is tracked and DEPLOYED, so whatever it names has to
# exist on every gateway. Commissioning rewrites it to a throwaway `temp_N`
# profile when it runs with identity files that outlived their data volume
# (scripts/setup.sh heals that) — and a temp profile exists on exactly one
# gateway, so committing it ships an auth policy pointing at nothing. Cheap
# check, because the failure mode is a locked-out gateway.
echo "→ identity policy (security-properties names a deployable profile)"
secprops="services/config/resources/core/ignition/security-properties/config.json"
if [ -f "$secprops" ]; then
  bad_profile="$(python3 -c 'import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: sys.exit(0)
print(" ".join(sorted({v for k,v in d.items()
                       if k in ("systemAuthProfile","systemIdentityProvider")
                       and str(v).startswith("temp")})))' "$secprops" 2>/dev/null || true)"
  if [ -n "$bad_profile" ]; then
    echo -e "  ${RED}security-properties points at a throwaway identity:${NC} $bad_profile"
    echo "  A commissioning run rewrote it. Restore it and drop the temp identity:"
    echo "    git checkout -- $secprops"
    echo "    rm -rf services/config/resources/core/ignition/{user-source,identity-provider}/temp*"
    echo "  (or just re-run scripts/setup.sh, which now repairs this)"
    rc=1
  else
    echo -e "  ${GREEN}ok${NC} — no throwaway identity in the deploy payload"
  fi
else
  echo -e "  ${YELLOW}skipped${NC} — $secprops not found"
fi

# 5. ign-lint (optional) -------------------------------------------------------
# Same command as the lint job, from the repo root (rule_config.json names its
# pylint config repo-root-relative). ign-lint exits non-zero on warnings too,
# so a view that CI rejects fails here first.
repo_root="$(git rev-parse --show-toplevel)"
lab_rel="${PROJECT_ROOT#"$repo_root"/}"
echo "→ ign-lint (projects/**/view.json)"
if command -v ign-lint > /dev/null 2>&1; then
  if (cd "$repo_root" && ign-lint --config "$lab_rel/rule_config.json" --files "$lab_rel/projects/**/view.json"); then
    echo -e "  ${GREEN}ok${NC}"
  else
    rc=1
  fi
else
  echo -e "  ${YELLOW}skipped${NC}: ign-lint not installed (CI runs it; pip install ign-lint==0.6.1)"
fi

# 6. yamllint + shellcheck (optional) -----------------------------------------
echo "→ yamllint (this lab + .github/workflows/lab06-*.yml)"
if command -v yamllint > /dev/null 2>&1; then
  if yamllint -c .yamllint.yml . "$repo_root"/.github/workflows/lab06-*.yml; then
    echo -e "  ${GREEN}ok${NC}"
  else
    rc=1
  fi
else
  echo -e "  ${YELLOW}skipped${NC}: yamllint not installed (CI runs it; pip install yamllint==1.35.1)"
fi
echo "→ shellcheck (scripts/*.sh)"
if command -v shellcheck > /dev/null 2>&1; then
  if shellcheck -x scripts/*.sh; then
    echo -e "  ${GREEN}ok${NC}"
  else
    rc=1
  fi
else
  echo -e "  ${YELLOW}skipped${NC}: shellcheck not installed (CI runs it)"
fi

echo "→ actionlint (.github/workflows/lab06-*.yml)"
if command -v actionlint > /dev/null 2>&1; then
  if actionlint -color -config-file .github/actionlint.yaml "$repo_root"/.github/workflows/lab06-*.yml; then
    echo -e "  ${GREEN}ok${NC}"
  else
    rc=1
  fi
else
  echo -e "  ${YELLOW}skipped${NC}: actionlint not installed (CI runs it; install from https://github.com/rhysd/actionlint to check locally)"
fi

# 7. docker compose config ------------------------------------------------------
echo "→ docker compose config"
if command -v docker > /dev/null 2>&1 && docker compose version > /dev/null 2>&1; then
  if docker compose config -q; then
    echo -e "  ${GREEN}ok${NC}"
  else
    rc=1
  fi
else
  echo -e "  ${YELLOW}skipped${NC}: docker compose not available"
fi

echo ""
if [ "$rc" -eq 0 ]; then
  echo -e "${GREEN}validate.sh: all checks passed${NC}"
else
  echo -e "${RED}validate.sh: one or more checks failed${NC}"
fi
exit "$rc"
