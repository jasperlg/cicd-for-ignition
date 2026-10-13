#!/usr/bin/env bash
#
# Prepare Part 2: set the shipped answer aside and drop in a starter skeleton.
#
# Part 2 has you REBUILD the workflow from scratch. GitHub only reads workflows
# from the repo root, so it lives at .github/workflows/lab03-ci.yml up there,
# not inside this lab folder. This script does only the two mechanical bits, so
# you can get straight to the interesting work:
#   1. moves the finished lab03-ci.yml out to this lab's .github/ci-reference.yml
#      (your answer key)
#   2. writes a bare two-job skeleton to .github/workflows/lab03-ci.yml (repo
#      root) for you to flesh out
#
# It does NOT write the real steps: the TODOs in the skeleton are yours to fill
# in across Part 2, steps 0-2 (the same numbers as exercises/lab.md and the
# assignment slides). Every action is announced as it happens.
#
# Re-running is safe: if the answer is already set aside, it won't clobber anything.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

# --- guard: inside the course repo? ---
if ! REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  echo "error: $PROJECT_ROOT is not inside a git clone of cicd-for-ignition." >&2
  exit 1
fi

# Paths below are relative to the lab folder (the script's working directory).
WORKFLOW="$REPO_ROOT/.github/workflows/lab03-ci.yml"
REFERENCE=".github/ci-reference.yml"
# The same two paths as you'd type them from the repo root, for the messages.
WORKFLOW_SHOWN=".github/workflows/lab03-ci.yml"
REFERENCE_SHOWN="labs/03-github-actions/$REFERENCE"

# Colour the step headers only when writing to a real terminal.
if [ -t 1 ]; then C=$'\033[1;36m'; B=$'\033[1m'; R=$'\033[0m'; else C=''; B=''; R=''; fi
say()  { printf '\n%s▸ %s%s\n' "$C" "$1" "$R"; }
note() { printf '  %s\n' "$1"; }

# --- guard: already prepared? ---
if [ -f "$REFERENCE" ]; then
  say "Already prepared, nothing to do."
  note "$REFERENCE_SHOWN exists, so the shipped answer is already set aside."
  [ -f "$WORKFLOW" ] && note "$WORKFLOW_SHOWN is in place: keep building it out."
  exit 0
fi

if [ ! -f "$WORKFLOW" ]; then
  echo "error: $WORKFLOW_SHOWN not found; expected the shipped workflow to move." >&2
  exit 1
fi

# --- action 1 of 2: set the answer aside ---
say "Action 1 of 2: set the shipped answer aside"
note "Running: ${B}git mv $WORKFLOW_SHOWN $REFERENCE_SHOWN${R}"
note "Keeps the finished workflow as a reference you'll check against in Part 2, step 4,"
note "while taking it out of .github/workflows/ so GitHub no longer runs it."
git mv "$WORKFLOW" "$REFERENCE"

# --- action 2 of 2: write the starter skeleton ---
say "Action 2 of 2: write a starter skeleton to $WORKFLOW_SHOWN"
note "A bare two-job skeleton (lint + validate) with TODOs: the real steps are"
note "yours to type across Part 2, steps 0-2. Nothing here does the exercise for you."
cat > "$WORKFLOW" <<'YAML'
name: Lab 03 · CI

# Monorepo scoping: only changes to this lab (or this workflow) trigger it.
# TODO (step 1): narrow `paths:` so docs-only PRs are skipped, plus a
# `push: branches: [main]` backstop. See the assignment.
on:
  pull_request:
    paths:
      - "labs/03-github-actions/**"
      - ".github/workflows/lab03-*.yml"

# Least-privilege default; individual jobs override if they need more.
permissions:
  contents: read

# Every `run:` step starts in the lab folder, as if you'd cd'd there yourself.
defaults:
  run:
    working-directory: labs/03-github-actions

jobs:
  # Job ids become the status-check names branch protection matches on:
  # keep `lint` and `validate` stable (renaming them orphans the required checks).

  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      # TODO (step 0): set up Python 3.12, then install the pinned tools
      #                (pip install yamllint==1.35.1 ign-lint==0.6.1)
      # TODO (step 0): run each linter: yamllint, actionlint, shellcheck, ign-lint
      # TODO (step 2): add `docker compose config -q` as the final lint step

  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      # TODO (step 0): run scripts/validate.sh
YAML

say "Done."
note "Answer key : $REFERENCE_SHOWN"
note "Your file  : $WORKFLOW_SHOWN  (repo root; starter skeleton, flesh out the TODOs)"
note "Next: commit, then fill in the jobs (Part 2, step 0) and work through steps 1-4."
