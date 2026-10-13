# Troubleshooting

Quick fixes for the things that bite people during this lab. Work top to bottom; most issues
are one of the first three.

## The stack won't start / `scripts/setup.sh` fails

- **Docker isn't running or isn't Compose v2.** `docker compose version` must work (note the space —
  not `docker-compose`). Start Docker Desktop and re-run `scripts/setup.sh` (it's idempotent).
- **Not enough RAM.** Three gateways at 1 GB each + TimescaleDB + the runner need **≥ 8 GB free**.
  If gateways crash or never reach RUNNING, raise Docker's memory or bump the per-gateway limit in
  [`docker-compose.yaml`](../docker-compose.yaml).
- **Port already in use** (`port is already allocated` from `docker compose up`). 8088/8089/8090
  (gateways), 8060/8061/8062 (Gateway Network) or 5432 (TimescaleDB) is taken by something else.
  Stop the other process, or pick free host ports in `.env` and re-run `scripts/setup.sh`:

  | Variable | Default | What |
  |---|---|---|
  | `GATEWAY_PORT` | 8088 | local gateway web UI |
  | `TEST_GATEWAY_PORT` | 8089 | test gateway web UI |
  | `PRODUCTION_GATEWAY_PORT` | 8090 | production gateway web UI |
  | `GATEWAY_GAN_PORT` / `TEST_GATEWAY_GAN_PORT` / `PRODUCTION_GATEWAY_GAN_PORT` | 8060 / 8061 / 8062 | Gateway Network |
  | `POSTGRES_PORT` | 5432 | TimescaleDB |

  Don't edit `docker-compose.yaml`: it reads these variables, and so do `scripts/setup.sh` and
  `scripts/scan.sh`. The deploy workflows reach the gateways by compose service name on the
  container port, so CI keeps working. Wherever the lab says `:8088` / `:8089` / `:8090`, use your
  ports instead (and in `flint.config.json` if you use Flint).

## Every tag reads null on the local gateway

The views load, but every tag-bound value shows `null` and *Connections → OPC Connections*
lists **Ignition OPC UA Server** as **FAULTED**. The gateway log says why:

```bash
docker logs lab04-ignition-local 2>&1 | grep 'opcua-module'
# Authentication failed: User Source "opcua-module" not found.
```

Every tag reads through that loopback connection, and it logs in against the
`opcua-module` user source. That user source holds a password hash, so it is gitignored and
never in a fresh clone; `scripts/setup.sh` has the OPC UA module create it on the next boot.
Re-run `scripts/setup.sh`: it prints `opcua-module user source created` and the connection
turns CONNECTED within a minute.

## A gateway never reaches RUNNING

- Give it time — a cold JVM start can take 60–120 s per gateway. `setup.sh` polls up to ~240 s each.
- Check logs (note: use `docker logs`, the container name — *not* `docker compose logs`, which wants
  the service name):
  ```bash
  docker logs --tail 200 lab04-ignition-local     # or -test / -production
  ```
- **Trial expired.** Each gateway runs in 2-hour trial mode. After it lapses the gateway stops
  serving. Reset via *Platform → Licensing → Reset Trial* (unlimited, legal for test).

## `git status` shows lots of `resource.json` changes

Ignition rewrites the `resource.json` manifests on every interaction, usually touching nothing
but volatile metadata (modification timestamp, actor, signature). That churn is **meant to be
visible** — real edits must show up in git — and it's undone, not hidden:

```bash
scripts/clean-ignition-resource-churn.sh          # dry run: lists volatile-only files
scripts/clean-ignition-resource-churn.sh --apply  # restores them from HEAD
```

Junk-only rewrites are reverted whether or not you already staged them. Files with real content
changes are never touched by the script.
`git diff` already hides the volatile metadata: `scripts/setup.sh` wires a textconv driver
(`scripts/git-diff/normalize-ignition-resource-json.py`) via `.gitattributes`. If diffs still
show timestamp/signature noise, re-run `scripts/setup.sh`.

The one exception is the machine-local `local-system-properties/config.json` (system UID, trial
state — it belongs to this specific box). `scripts/setup.sh` and the post-checkout hook it installs
keep it `skip-worktree` so it never dirties the tree. To intentionally change that seed file and
commit it:
```bash
git update-index --no-skip-worktree <path>
# edit, commit, push — re-run scripts/setup.sh to re-apply skip-worktree
```

## The self-hosted runner is offline / jobs queue forever

- Container up? `docker compose ps github-runner` and `docker logs lab04-runner` (look for
  *"Listening for Jobs"*).
- **Restart loop with a *401* in the logs?** The runner authenticates with the `repo`-scope PAT in
  `RUNNER_GITHUB_PAT` (`.env`) — a 401 means it's still the placeholder or an invalid/expired token.
  Fix it, then `docker compose up -d --force-recreate github-runner`.
- `RUNNER_REPO_URL` in `.env` must point at **your fork**, not the upstream.
- `RUNNER_GITHUB_PAT` in `.env` must be a real GitHub Personal Access Token with `repo` scope
  (make one at github.com/settings/tokens → classic → tick `repo`; keep it, Lab 06 reuses it).
- In your fork: *Settings → Actions → Runners* should list it online with the `self-hosted, lab04`
  labels.
- Don't add `EPHEMERAL` to the runner's environment in `docker-compose.yaml` — the image treats
  **any** non-empty value (even `"false"`) as "enable ephemeral mode", which deregisters the runner
  after every job.

## The scan step fails with HTTP 401

The gateway rejected the key. The `IGNITION_API_KEY` secret on that GitHub environment
(`lab04-gateway-test` / `lab04-gateway-production`) is missing, wrong, or not the target gateway's
own key. `scripts/setup.sh` generated one key per gateway into `.env`: set the secret to the matching
`IGNITION_API_KEY_TEST` / `_PRODUCTION` value. Keys are **per-gateway**, so a test key won't
authenticate against production. The workflow fails fast here, without restarting anything.

If the secret does match `.env`, the gateway has no token on disk (for example the stack was
started with plain `docker compose up` and `gateways/<gw>/config` was wiped since). The keys are not
in git at all: `scripts/setup.sh` (via `scripts/generate-api-keys.sh`) generates them into `.env` and
writes each gateway's token resource onto its disk before first boot, and the deploy wipe **spares**
`api-token/`. Re-run `scripts/setup.sh`: it re-derives every token from the keys in `.env`, seeds
them, and restarts what needs restarting.

## The first deploy restarts the gateway

Expected. A fresh test or production gateway boots before its config mode (`test` /
`production`) is on its disk, and Ignition picks its deployment mode at boot. So the scan step asks
the gateway which mode it runs in; on the first deploy that's none, and it restarts the gateway
once to load the mode and everything just shipped. Every later deploy scans hot, no restart.

A **403** on the scan means the key is valid but lacks permission: first-boot commissioning reset
`security-properties`, and the Ship step just copied the repo's copy back, which the gateway reads
at boot. The scan step restarts the gateway once and retries.

The same applies to failing **manual** scans (`scripts/scan.sh`): re-run `scripts/setup.sh`.

## Locked out of test/production after a deploy (admin password rejected)

Historically this happened when a deploy shipped the repo's copy of
`config/resources/core/ignition/user-source/` — its `users.json` carries the **local** gateway's
admin password hash, so it overwrote the target's own admin user. The current workflows spare the
gateway-owned internal identity **by name** — `user-source/default/`, `user-source/opcua-module/`,
and `identity-provider/default/` — in the wipe, and `.deployignore` keeps those dirs out of the
payload, so this shouldn't happen anymore. (Other user sources and identity providers — database,
AD, SAML/OIDC — hold no password data and deploy normally, as does `security-properties`.) If you
still hit it (e.g. an older working tree):

- **Full reset:** `scripts/teardown.sh --volumes`, then `scripts/setup.sh`. Nukes all gateway state.
- **Targeted:** delete `gateways/<gw>/config/resources/core/ignition/user-source`, then re-run
  `scripts/setup.sh` — it notices the missing identity, recreates that gateway's data volume so
  commissioning runs again, and the admin user comes back from the `GATEWAY_ADMIN_*` values in
  `.env`. (Deleting the files alone is not enough: the old volume still says "already
  commissioned", so the gateway would boot with no identity at all.)

## Login page says `Identity provider not found: default` (HTTP 500)

The gateway is running but has no internal identity on disk. Classic cause: a **fresh clone next
to an old stack** — you deleted or re-cloned the repo folder without `scripts/teardown.sh
--volumes` first. Docker Compose reuses data volumes by project (folder) name, so the gateway
boots against the old volume, believes it is already commissioned, and never re-creates the
`default` user source / identity provider that used to live in the (now gone) config tree.

**Fix:** re-run `scripts/setup.sh`. It detects the desync (volume exists, identity missing) and
recreates the affected gateway's container + volume so commissioning runs again. Rule of thumb:
always `scripts/teardown.sh --volumes` before deleting or re-cloning the folder.

## I merged my PR but nothing deployed (GitHub Flow)

This lab uses GitHub Flow — the branch decides the gateway:

- **Did your PR actually merge into `main`?** `lab04-deploy.yml` fires on pushes to `main`, and merging a PR is what produces that push. If the PR is still open (or merged into some other branch), nothing ships to test.
- **Did the change touch a deploy path?** Confirm it hit `projects/**` or `services/config/**`; a docs-only push to `main` is filtered out by the `paths:` filter.
- **Is Actions enabled on your fork?** No enabled workflows means no runs at all. Check *Settings → Actions* on your fork.
- **Production doesn't update on a `main` merge — that's intentional.** Production is reached by **tagging**: `git tag lab04-vX.Y.Z && git push origin lab04-vX.Y.Z` fires `lab04-release.yml`.

## The deploy ran but my change isn't visible

- Are you looking at the right gateway? `local` = :8088, `test` = :8089, `production` = :8090.
- Did the scan return HTTP 200? `scripts/scan.sh` pretty-prints the response with a
  `lastScanTimestamp`. Files on disk without a successful scan = gateway hasn't reloaded.
- Module enable/disable (`services/modules.json`) needs a **restart**, not a scan:
  `docker compose restart ignition-test`.

## Validate before you push

```bash
scripts/validate.sh    # JSON parse + .deployignore syntax + actionlint — mirrors CI
```

Still stuck? Ask the instructor or post in the course Discord.


## Why resource.json keeps changing on its own

See [`resource-json-hygiene.html`](./resource-json-hygiene.html) for the full picture: what the junk fields are, the difference between hiding them and reverting them, and why an empty `git diff` does not mean the file on disk is clean.
