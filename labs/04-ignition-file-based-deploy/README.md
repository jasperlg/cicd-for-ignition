# Lab 04 — Ignition file-based deploy

Day 2 (afternoon) of the [CI/CD for Ignition Masterclass](../../README.md).

> Decode the Ignition 8.3 file structure, then build a file-based deploy pipeline that promotes project changes from a local working gateway, through a test environment on push to `main`, to a production environment on a tag release cut from `main` — all with a hot scan, no gateway restarts. The pipeline follows **GitHub Flow**.

This is the **first lab that opens up the Ignition gateway itself**. Labs 02–03 already worked with a real Ignition project — a Perspective HMI and a couple of Python script libraries running on a gateway you spin up — but kept the gateway's *administrative* side (config, modules, databases, deploys) deliberately abstracted away: the repo tracked only project files, and the gateway generated its own config into a volume you never touched. This lab pulls that curtain back — the `data/` file structure, gateway-level config, and how to deploy it — and points it at three real gateways that simulate a local → test → production promotion flow.


> **How resource.json stays clean:** Ignition restamps these manifests constantly. [`docs/resource-json-hygiene.html`](./docs/resource-json-hygiene.html) explains what the junk is, the two tools that deal with it, and why an empty `git diff` does not mean a clean file.

## Prerequisites

- Your fork of the course repo, `<you>/cicd-for-ignition`, with Actions enabled (the self-hosted runner registers against your fork, not the upstream)
- A GitHub Personal Access Token with `repo` scope — the bundled runner uses it to auto-register against your fork. Create it at [github.com/settings/tokens](https://github.com/settings/tokens) (Generate new token → classic → tick `repo`) and put it in `.env` as `RUNNER_GITHUB_PAT` (the root `course-setup.sh` asks for it once and writes it there for you). You make it once here; **Lab 06 reuses the same token** (Lab 05 has no runner). It never leaves `.env`.
- The [GitHub CLI](https://cli.github.com/) (`gh`), authenticated (`gh auth status`) — used to fork and clone the course repo
- **≥ 8 GB free RAM for Docker** — three Ignition gateways each cap at 1 GB, plus TimescaleDB, the runner, and the usual Docker Desktop overhead
- _Optional but recommended:_ pass the [preflight](../../preflight/) checks so unrelated env issues don't bite you mid-lab
- _Background reading:_ [Lab 03](../03-github-actions/) covers the GitHub Actions fundamentals this lab builds on, but this lab stands alone — the self-hosted runner ships in `docker-compose.yaml`, no manual `docker run` of `myoung34/github-runner` required


> **WSL2 (Windows): keep the clone in your Linux home (`~/…`), never `/mnt/c/…`.**
> On the Windows filesystem your Windows user, your WSL user and the gateway's
> container user are three different identities, so file ownership breaks in ways
> `chown` cannot fix and you end up reaching for `sudo` (which makes it worse).
> `scripts/setup.sh` refuses to run from there, and never needs `sudo`.
> See [`docs/wsl-setup.md`](./docs/wsl-setup.md).

## Quick start

```bash
# Fork + clone once for the whole course (skip if you already have it):
#   mkdir -p ~/mustry-academy && cd ~/mustry-academy && gh repo fork Mustry-Academy/cicd-for-ignition --clone
cd ~/mustry-academy/cicd-for-ignition/labs/04-ignition-file-based-deploy
cp -n .env.example .env   # no-op if course-setup.sh already created it
scripts/setup.sh    # brings up the stack, waits for all three gateways, prints credentials
```

> **One lab stack at a time:** every lab uses the same ports. Stop the previous lab's stack first (`docker compose down` in that lab's folder, e.g. `../03-github-actions`). Something else on your machine already holds a port? Set `GATEWAY_PORT`, `TEST_GATEWAY_PORT`, `PRODUCTION_GATEWAY_PORT`, `POSTGRES_PORT` (or the `*_GAN_PORT` ones) in `.env`; see [`docs/TROUBLESHOOTING.md`](./docs/TROUBLESHOOTING.md).

Once setup finishes you have three Ignition gateways:

| Gateway | URL | Source of project files |
|---|---|---|
| `local` | http://localhost:8088 | Bind-mounted from `./projects/` and `./services/config/` — edits show up immediately |
| `test` | http://localhost:8089 | Empty until `lab04-deploy.yml` runs on push to `main` — deployed files visible on the host under `./gateways/test/` |
| `production` | http://localhost:8090 | Empty until `lab04-release.yml` runs on tag push `lab04-v*` (cut from `main`) — deployed files visible under `./gateways/production/` |

Login to any of them with the credentials from `.env` (`GATEWAY_ADMIN_USERNAME_LOCAL/_TEST/_PRODUCTION`, default `admin / password`).

> **Trial mode:** each gateway runs in 2-hour trial mode. Reset via *Platform → Licensing → Reset Trial* — unlimited and entirely legal for development. You'll do this **three times** if you keep all three gateways up long enough.

> **Stuck?** See [`docs/TROUBLESHOOTING.md`](./docs/TROUBLESHOOTING.md) for the common stack / runner / deploy failures and their fixes. Before opening a PR, run `scripts/validate.sh` (the quick JSON / `.deployignore` checks) and, if you have `pre-commit` installed, the yamllint / shellcheck / actionlint / ign-lint suite CI runs — it fires on every commit that touches this lab, or run it by hand from the repo root: `pre-commit run --all-files --config labs/04-ignition-file-based-deploy/.pre-commit-config.yaml`.

## Lab structure

The lab is one exercise in two ordered parts — see [`exercises/lab.md`](./exercises/lab.md):

1. **Ignition 8.3 file structure decoded** — know every file in `data/`: what it is, who owns it, whether it belongs in git.
2. **File-based deploy mechanic** — ship project changes local → test → production, hot scan, no restarts.

> Image-based deploys come next, on Day 3 ([image-based](../05-ignition-image-based-deploy/)); multi-gateway deployments follow on Day 4 ([multi-gateway](../07-multi-gateway-deploy/)).

## Repo layout

```
labs/04-ignition-file-based-deploy/
├── README.md
├── docker-compose.yaml                 ← three Ignition gateways + TimescaleDB + bundled self-hosted runner
├── .env.example                        ← copy to .env before running
├── .deployignore                       ← what NOT to copy onto test/production gateways
├── .gitattributes                      ← JSON line-ending normalization + binary markers
├── .pre-commit-config.yaml             ← local git hooks: the same linters CI runs (carried from Lab 03)
├── .yamllint.yml                       ← yamllint config
├── .shellcheckrc                       ← lets shellcheck resolve the sourced scripts/lib.sh
├── rule_config.json                    ← ign-lint (Perspective view) rules
├── .github/
│   └── actionlint.yaml                 ← declares the self-hosted `lab04` runner label
├── exercises/
│   └── lab.md                          ← the lab, in two ordered parts
├── db-init/                            ← timescaledb initialisation: create ignition_test and ignition_production databases
├── docs/                               ← reference reading
│   ├── ignition-file-structure.md
│   └── file-based-deploy-pattern.md
├── scripts/
│   ├── setup.sh                        ← bootstraps the whole stack
│   ├── teardown.sh                     ← stop the stack (with --volumes to wipe)
│   ├── generate-api-keys.sh            ← per-gateway scan-API keys into .env + token resources (never committed; run by setup.sh)
│   ├── scan.sh                         ← curl the scan API (local | test | production)
│   ├── lib.sh                          ← shared helpers
│   ├── clean-ignition-resource-churn.sh ← undo volatile-only resource.json rewrites (dry-run / --apply)
│   ├── git-diff/                       ← textconv normalizer that hides volatile metadata in diffs
│   └── git-hooks/                      ← post-checkout hook (run by the repo-root dispatcher): skip-worktree for the machine-local config file
├── projects/                           ← project content (bind-mounted into `local` only)
│   ├── example-project/                ← a real Perspective project (views, templates)
│   └── packaging-site/                 ← a second project; proves one deploy ships every project under projects/
├── gateways/                           ← test/production gateway state (gitignored; bind-mounted projects/ + config/)
├── services/
│   ├── config/                         ← gateway-level config (bind-mounted into `local`)
│   │   └── resources/                  ← <scope>/<module-id>/<resource-type>/<name>/{config.json,resource.json}
│   └── modules.json                    ← module enablement (shared by all three gateways)
├── third-party-modules/                ← bundled .modl binaries the gateways install at startup
└── tests/                              ← validation scaffold (see scripts/validate.sh)
```

The workflows live at the repo root, because GitHub only runs workflows from there:

```
.github/workflows/
├── lab04-ci.yml                        ← PR validation: linters + JSON/.deployignore (ubuntu-latest, free)
├── lab04-deploy.yml                    ← push to main → test gateway (self-hosted)
└── lab04-release.yml                   ← tag lab04-v* on main → production gateway (self-hosted)
```

## The Compose stack

Three Ignition 8.3 gateways + one TimescaleDB. The three gateways simulate the classic local → test → production promotion:

- **`ignition-local`** bind-mounts `./projects/` and `./services/config/` from the host. Anything you write into those paths on your laptop is *immediately on disk* inside the local gateway. Hit `scripts/scan.sh` to make the gateway notice. That's the tight inner feedback loop.
- **`ignition-test`** bind-mounts its `projects/` and `config/` from `./gateways/test/` (gitignored — this is the *gateway's* state, not the repo's). It starts empty; the deploy workflow (`lab04-deploy.yml`) `docker cp`s the working tree into the container and triggers a scan. Because the target dirs are bind mounts, you can verify a deploy landed straight from your laptop: `ls gateways/test/projects`. Mirrors how a real shared test environment gets fed by CI.
- **`ignition-production`** is the same shape as test, populated by the release workflow (`lab04-release.yml`) when you push a tag.

The single TimescaleDB hosts three logical databases (`ignition_local_development`, `ignition_test`, `ignition_production`) so each gateway can have its own historian data without crosstalk.

Memory is set to 1 GB per gateway via Compose limits. Tight but workable; bump it in `docker-compose.yaml` if you see GC pauses.

## Branching model (GitHub Flow)

This lab uses **GitHub Flow**: one long-lived branch (`main`), always deployable, with short-lived `feature/*` branches PR'd back into it.

```
feature/*  ─PR→  main ──push→  lab04-deploy.yml ──docker cp + scan──→ TEST gateway
                 main ──tag lab04-vX.Y.Z→ lab04-release.yml ──docker cp + scan──→ PRODUCTION gateway
```

| Branch | Role | What it does |
|---|---|---|
| `main` | The single long-lived branch — always deployable | a **push** to `main` (merging a feature PR) fires `lab04-deploy.yml` → **test** gateway; you **tag** `lab04-vX.Y.Z` on it to release to production |
| `feature/*` | Day-to-day work, branched off `main`, PR'd back into `main` | `lab04-ci.yml` validates the PR into `main` |

The **tag** on `main` is your **freeze point**: tag the commit you want in production (`lab04-vX.Y.Z`). The tag — not the merge — is what `lab04-release.yml` ships, so production always runs a named, re-deployable version.

## A note on the CI/CD workflows

Three workflows under the repo root's [`.github/workflows/`](../../.github/workflows/). Each only fires for changes under `labs/04-ignition-file-based-deploy/` (or to the workflow file itself), and every step runs inside this lab's folder:

| File | Trigger | Runner | Purpose |
|---|---|---|---|
| [`lab04-ci.yml`](../../.github/workflows/lab04-ci.yml) | PR to `main` | `ubuntu-latest` (free) | Validate JSON, `.deployignore` syntax, and the workflow files themselves. |
| [`lab04-deploy.yml`](../../.github/workflows/lab04-deploy.yml) | Push to `main` (deploy paths only), manual | `[self-hosted, lab04]` | File-based deploy to the **test** gateway via `docker cp`. |
| [`lab04-release.yml`](../../.github/workflows/lab04-release.yml) | Tag `lab04-v*` (on `main`), manual | `[self-hosted, lab04]` | File-based deploy to the **production** gateway. Same mechanics, different environment. |

> `lab04-deploy.yml` has a `paths:` filter (this lab's `projects/**`, `services/config/**`, `.deployignore`, `scripts/scan.sh`, `scripts/lib.sh`, plus `.github/workflows/lab04-deploy.yml`), so a push to `main` that only touches docs or the README does **not** trigger a deploy — edit project or config content to see it fire.

> The deploy and release jobs carry `if: github.repository != 'Mustry-Academy/cicd-for-ignition'`. They deploy to gateways on your machine, so they only run in your fork and skip on the course repo itself. CI (`lab04-ci.yml`) runs in both.

Both deploy workflows need:

- The bundled self-hosted runner (`github-runner` service in `docker-compose.yaml`) registered against your fork with the `lab04` label. It auto-registers using the `repo`-scope PAT in `RUNNER_GITHUB_PAT` (see `.env`), and shares the host's Docker daemon (mounted `/var/run/docker.sock`) so the workflows can `docker cp` files into the test/production gateway containers. If you'd rather use your own runner instead, set `runner.labels` to include `lab04` and skip the bundled service.
- A GitHub **environment** per workflow with the right secret + variables:

| Scope | Name | Type | Purpose |
|---|---|---|---|
| Environment `lab04-gateway-test` (lab04-deploy.yml) | `IGNITION_API_KEY` | Secret | The `IGNITION_API_KEY_TEST` value from your `.env` — `setup.sh` generates a unique key per gateway (nothing key-related is committed) |
| Environment `lab04-gateway-test` | `IGNITION_URL` | Variable (optional) | Defaults to `http://ignition-test:8088` (bundled-runner case). Override to `http://localhost:8089` if your runner is on the host. |
| Environment `lab04-gateway-test` | `IGNITION_CONTAINER` | Variable (optional) | Defaults to `lab04-ignition-test` |
| Environment `lab04-gateway-production` (lab04-release.yml) | (same three) | | Defaults: URL `http://ignition-production:8088`, container `lab04-ignition-production` |

Add **required reviewers** on the `lab04-gateway-production` environment if you want a manual approval gate on tag releases — common pattern, no workflow change required.

The deploy part of [`exercises/lab.md`](./exercises/lab.md) walks through the end-to-end setup.

## Licence

Apache 2.0 — see [`LICENSE`](./LICENSE).
