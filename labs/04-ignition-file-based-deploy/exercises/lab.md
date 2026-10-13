# Lab 04 — The Ignition 8.3 file structure & a file-based deploy pipeline

**Duration:** ~3 hours in total: the 60-minute teaching block, then two parts

1. **Decode the Ignition 8.3 file structure** (~65 min) — know every file in a gateway's `data/` directory: what it is, who owns it, whether it belongs in git.
2. **Build the file-based deploy** (~55 min) — wire that knowledge into GitHub Actions: a push to `main` ships to the test gateway, a tag on `main` ships to production. Hot scan, no restarts.

The second part automates exactly what you do by hand in the first. Do them in order.

## Goal

You should leave this lab able to:

- Navigate an Ignition 8.3 gateway's `data/` directory and name what each top-level item is for
- Explain the difference between **project-level**, **gateway-level**, and **operational** state, and decide which files belong in git
- Predict which files appear on disk when you make a given change in the gateway UI
- Describe the file-based deploy pattern in five steps: **checkout → prune → ship → scan → verify**
- Run a deploy manually, then wire the same flow into the bundled GitHub Actions self-hosted runner following **GitHub Flow**: a push to `main` promotes to **test**, and a tag on `main` promotes to **production**
- Read [`.deployignore`](../.deployignore) and explain why each pattern is in there

## Pre-flight

```bash
cd ~/mustry-academy/cicd-for-ignition/labs/04-ignition-file-based-deploy
cp -n .env.example .env   # no-op if course-setup.sh already created it
scripts/setup.sh    # idempotent — brings up the stack and waits for all three gateways
# When it finishes:
curl -fsS http://localhost:8088/StatusPing
```

Open <http://localhost:8088> (the `local` gateway) in your browser. (Did `docker compose up` report a port that is already allocated? Set other host ports in `.env`, see [`docs/TROUBLESHOOTING.md`](../docs/TROUBLESHOOTING.md), and use those wherever this lab says `:8088` / `:8089` / `:8090`.) Login: `admin` / `password` (or whatever you set as `GATEWAY_ADMIN_PASSWORD_LOCAL` in `.env`). The test and production gateways (`:8089` / `:8090`) come up too but stay empty until the deploy part.

Before you start the deploy part, get these in place (they take a few minutes and the #1 "nothing deploys" cause is forgetting to enable Actions on the fork — or a push that only touched docs, which the `paths:` filter skips):

- **Your fork of the course repo (`<you>/cicd-for-ignition`), with Actions enabled.** The bundled runner registers against your fork, not the upstream. Forks ship with workflows **disabled** — if you haven't yet, open your fork's *Actions* tab and click "I understand my workflows, go ahead and enable them." (Once per fork, not per lab.)
- **`gh` pointed at your fork:** `gh repo set-default <you>/cicd-for-ignition`. You did this once for the course clone; `gh repo set-default --view` confirms it. Without it, `gh` commands (like `gh pr create`) ask which repo you mean, or worse, target the course repo instead of your fork.
- **A GitHub Personal Access Token (PAT) with `repo` scope**, plus `RUNNER_REPO_URL` in `.env` pointed at **your fork** (`https://github.com/<you>/cicd-for-ignition`). If you ran the root `course-setup.sh`, both are already in `.env`. The bundled `github-runner` container uses the PAT to auto-register against your fork. You create this token once here; **Lab 06 reuses the same one** (Lab 05 has no runner), so keep it somewhere safe. To create it:
  1. Go to **github.com/settings/tokens** → **Generate new token** → **Generate new token (classic)**.
  2. Give it a name (e.g. `cicd-course-runner`) and tick the **`repo`** scope.
  3. Click **Generate token** and copy the `ghp_...` value (you can't read it back later).
  4. Paste it into `.env` as `RUNNER_GITHUB_PAT=ghp_...`. It stays in `.env` and is never committed.
- **Fork PR approval on your fork.** Lab 03 taught: never attach a self-hosted runner to a public repo that accepts fork PRs. This lab does exactly that on purpose: your fork is public, and the runner holds the Docker socket, which is root on your laptop. The deploy workflows only fire on a push to `main` or a tag, which a fork PR cannot cause, but a PR can edit any workflow to say `runs-on: [self-hosted, lab04]` and its `pull_request` run would execute on your machine. It is acceptable here because the runner only lives for the lab, nobody else opens PRs on your fork, and you switch on the guard rail first: your fork's **Settings → Actions → General → Approval for running fork pull request workflows from contributors → Require approval for all external contributors → Save**. A PR from anyone who is not a collaborator then waits for your click before any job starts. Same thing from the CLI:
  ```bash
  echo '{"approval_policy":"all_external_contributors"}' | gh api -X PUT repos/<you>/cicd-for-ignition/actions/permissions/fork-pr-contributor-approval --input -
  ```
  Stop the runner when the course is over (`docker compose down` in this folder).
- **An Ignition API key per gateway you want to scan.** You already have these: `scripts/setup.sh` generated a key per gateway into `.env` (`IGNITION_API_KEY_LOCAL` / `_TEST` / `_PRODUCTION`), unique to your clone, and installed the matching token on each gateway. Nothing key-related is in git — a committed key would be a working credential in every fork. (In the gateway UI you'd do the same by hand: *Platform → Security → API Keys → Create API Key*. 8.3 has no scan-only scope: a key gets a security level, and the scan API needs that level in *Gateway Write Permissions*, as in Lab 02.)
- **GitHub Environments** for the deploy workflows: `lab04-gateway-test` for `lab04-deploy.yml`, `lab04-gateway-production` for `lab04-release.yml`. Each needs a secret `IGNITION_API_KEY` (the matching `_TEST` / `_PRODUCTION` value from your `.env`).

Read-ahead: [`docs/ignition-file-structure.md`](../docs/ignition-file-structure.md) and [`docs/file-based-deploy-pattern.md`](../docs/file-based-deploy-pattern.md).

---

# Part 1 — Decode the Ignition 8.3 file structure

## Tour: the `data/` directory (guided, ~15 min)

Walk the gateway's `data/` directory live, both from the inside (via `docker exec`) and from the outside (the host bind mounts).

```bash
docker exec -it lab04-ignition-local bash -lc "ls -la /usr/local/bin/ignition/data"
```

In order:

1. **`projects/<name>/`** — project-level state. One directory per project. Inside: `project.json` + module-namespaced resource folders, e.g. `com.inductiveautomation.perspective/views/pages/<Page>/{view.json, resource.json}` and `ignition/`. *This is the thing you'll deploy via file-based CI/CD.* (`projects/.resources/` next to them is generated, see 8.)
2. **`config/resources/<scope>/`** — gateway-level config, organized scope-first (`core`, `local-development`/`test`/`production`, `local`) then by module: `core/ignition/database-connection/<name>/`, `identity-provider/<name>/`, `tag-provider/<name>/`. Shared across all projects.
3. **`config/`** root — next to `resources/`: `config/local/` (this box's Gateway Network keystore and UUID) and the runtime tag value store `config/ignition/tags/valueStore.idb`. Small, mostly operational.
4. **`modules.json`** — which modules the gateway has enabled. Gateway-level. (Repo source: `services/modules.json`.)
5. **`modules/`** — per-module **data** folders the modules write at runtime (here `modules/flint/`). Operational. The module *binaries* (`.modl`) are not in `data/` at all: the built-in ones ship in the image at `/usr/local/bin/ignition/user-lib/modules/`, and this lab's third-party ones are mounted at `/third-party-modules`.
6. **`db/`** — the internal SQLite DB (`config.idb`), which includes the internal user store (password hashes, lockout state). **Operational state.** Never commit.
7. **`jar-cache/`, `metricsdb/`, `var/`** — runtime / generated stuff. Never commit. (Gateway logs live outside `data/`, at the install root.)
8. **`.resources/`** — Ignition's content-addressed blob store. Not at the top of `data/`: one sits in `config/resources/.resources/` and one in `projects/.resources/`, inside the trees you version. Generated, so gitignored and never deployed.
9. **The small files at the top** — set once, then owned by this gateway, so operational:
   - **`gateway.xml`** — web server settings: HTTP/HTTPS ports, Gateway Network port, thread pools.
   - **`ignition.conf`** — the Java wrapper config: memory, JVM arguments. In this lab the compose `command:` sets those (`-m 1024`, `-Dignition.config.mode=…`).
   - **`certificates/`** — this gateway's TLS and trusted certificates.
   - **`commissioning.json`** — the "already commissioned" marker (EULA, first-boot choices). Delete it and the gateway runs commissioning again.
   - **`redundancy.xml`** — the redundancy role (independent / master / backup) of this node.
   - **`email-profiles/`** — a runtime folder of the email notification feature (empty here).
   - Plus dotfiles and backups the gateway or the container image writes for itself (`.gateway.xml.bak`, `init.properties.bak`, `.container-init.conf`, …). Ignore them.

The three-bucket model:

```
PROJECT-LEVEL     GATEWAY-LEVEL              OPERATIONAL
projects/<x>/     config/resources/          db/, jar-cache/, metricsdb/, var/,
                  modules.json               modules/, .resources/, config/local/,
                                             gateway.xml, ignition.conf, certificates/,
                                             commissioning.json, redundancy.xml,
                                             email-profiles/
                                             (anything the gateway owns or that changes
                                              at runtime without you touching it)
```

The deploy story is different for each bucket:

- **Project-level:** copy → trigger project scan. No restart needed.
- **Gateway-level:** copy → trigger config scan. *Sometimes* a restart is needed (depends on what changed).
- **Operational:** never deployed. Gateway owns this state; backups are the recovery mechanism.

## Find the file (guided, ~15 min)

The marker trick: set a timestamp marker, make the change in the UI, then ask `find` what's newer.

1. `docker exec -it lab04-ignition-local bash -lc "ls -la /usr/local/bin/ignition/data"` — list every top-level entry. Note what each is. (Operational paths like `db/`, `jar-cache/`, `metricsdb/` live in the container's named volume, so you'll only see them via `docker exec`, not on the host bind mount.)
2. **Set a marker** so you can spot which files a UI change touches:
   ```bash
   docker exec lab04-ignition-local touch /tmp/marker
   ```
3. In the gateway UI, go to **Platform → Gateway Settings** (the *Edit Notes* link on the Home page lands there too). Change the *Welcome Screen Notes* text in the General section. Save.
4. Find the file that changed on disk:
   ```bash
   docker exec lab04-ignition-local find /usr/local/bin/ignition/data/config -newer /tmp/marker -type f 2>/dev/null
   ```
5. Open that file with `docker exec lab04-ignition-local cat <path>`. Notice what's in there — it'll be a `config.json` (plus the gateway rewriting a sibling `resource.json`). Look at the scope in its path, too: the page's *Deployment Modes* selector was on `local-development`, so that is the definition you just edited.
6. In the gateway UI, **Connections → Databases → Connections → Create Database Connection**. Add a Postgres datasource named **`Scratch`**. In 8.3.8 the create form takes a single **Connect URL**: `jdbc:postgresql://timescaledb:5432/ignition_local_development`, username `ignition`, and for **Password** pick **Embedded** and type `ignition` (the `POSTGRES_USER` / `POSTGRES_PASSWORD` values from your `.env`). Save. The hostname `timescaledb` is the compose service name and `5432` the container port: the local gateway resolves both on the lab's docker network, whatever host port you mapped.

   > **Which collection did that land in?** A UI edit lands in the deployment-mode collection selected in the *Deployment Modes* bar at the top of the page. On the local gateway that is `local-development`, so `Scratch` is created in `config/resources/local-development/`, an override only the local gateway reads. A resource every environment should share must be created under **`core`** (switch the bar to `core` first), or moved there on disk.
7. Repeat step 4 (re-touch the marker first) — find the new files. The connection lands at `config/resources/<scope>/ignition/database-connection/Scratch/config.json`. Which `<scope>`? Gateway-level or project-level? Because `local` bind-mounts `./services/config/`, it also just appeared **in your repo on the host** — run `git status`.

## "Everything is a file in git" (guided, ~10 min)

Prove that the things people assume live "inside Ignition somewhere" are all plain files you can read, diff, and commit. Do these from the repo root on your host (no gateway needed — they're already on disk under `services/` and `projects/`).

1. **Every database connection is a file.** Open `services/config/resources/core/ignition/database-connection/TimescaleDB/config.json`. This is the whole connection: JDBC URL, pool sizes, the (encrypted) password. Nothing hidden in a gateway database.

2. **Every PLC / device connection is a file.** Open `services/config/resources/core/com.inductiveautomation.opcua/device/Simulator/config.json` and `.../ignition/opc-connection/Ignition OPC UA Server/config.json`. The lab ships a **simulator** device on disk; in a real plant this same file would describe your Modbus / OPC-UA PLC. Your PLC wiring is version-controlled, reviewable config, not clicks in a UI.

3. **Tags are files too.** Open `services/config/resources/core/ignition/tag-definition/example-tags/tags.json` (and the UDT definitions under `ignition/tag-type-definition/example-tags/udts.json`). Tag providers, tags, and UDTs all serialize to JSON on disk. (The runtime *values* live in `services/config/ignition/tags/valueStore.idb`, which is operational and never committed — the definitions are, the live values are not.)

4. **Deployment modes: one config set, many environments.** This is an Ignition 8.3 platform feature, not a lab trick. The scopes you saw (`core`, `local-development`, `test`, `production`) are **deployment modes**: the same resource name resolves to different settings per mode, and the gateway picks the mode at boot with `-Dignition.config.mode=<scope>`. See it directly:
   ```bash
   diff services/config/resources/local-development/ignition/database-connection/TimescaleDB/config.json \
        services/config/resources/production/ignition/database-connection/TimescaleDB/config.json
   ```
   Exactly one line differs: the `connectURL` points at `ignition_local_development` vs `ignition_production`. Same connection *name*, same everything else (that falls through to `core`), one per-mode override. The real-world version: a device named `PLC-01` is a **simulator in test** and the **real device in production**, under one name, so your project code never changes.

5. **Where is the CSS "hidden"?** In Perspective, styling lives in a few honest places, all of them files:
   - **Inline component styles** live right in the view: open `projects/example-project/com.inductiveautomation.perspective/views/pages/refrigeration/view.json` and find the `style` props on components.
   - **Style classes** (reusable named styles) are a *project resource* under `com.inductiveautomation.perspective/style-classes/<name>/` when a project defines them. This repo styles inline, so it has none, but that is where they land.
   - **Themes** (the gateway-wide look) are gateway-level theme CSS the gateway generates under `data/`.

   The takeaway: there is no secret CSS store. It is inline in views, or a style-class resource, or a gateway theme file — all readable, all diffable.

## Solo: make three changes, classify every one (~25 min)

Make a series of changes in the gateway UI and answer: **which bucket is each in, and where does it live on disk?**

Pick three changes from this list (or invent your own). For each note:

- **What you changed** (one sentence)
- **Where it lives on disk** (path relative to `data/`)
- **Bucket**: project-level / gateway-level / operational
- **One sentence: would you commit this to git?**

> This repo ships **two** projects under `projects/`: `example-project` and `packaging-site`. Each project is a self-contained directory; the gateway config (connections, tags, deployment modes) is **shared** across both. That split — per-project resources vs one shared gateway config — is the whole point of the project-level vs gateway-level buckets.

Suggested changes:

1. Add a **Perspective view** to one of the two projects. No Designer? Simulate on disk: create `projects/packaging-site/com.inductiveautomation.perspective/views/pages/<Name>/{view.json, resource.json}` with the minimal 8.3 content from [`docs/ignition-file-structure.md`](../docs/ignition-file-structure.md). Note the `resource.json` manifest is **required** in 8.3, and that this lands under *one* project only, unlike a gateway resource.
2. Add a **device connection** (Connections → Devices → Connections, e.g. a Simulator)
3. Add a **new user** to the gateway (Platform → Security → User Sources → ⋮ on `default` → Manage Users)
4. Add a **new tag provider** (Services → Tags → Create Tag Provider)
5. Enable a **new module** (toggle a module in Platform → Modules)

Use the marker trick every time: re-touch before each change, `find -newer` after. One of the five lands somewhere that must **never** go in git. Which?

## Definition of done (part 1)

You're finished with part 1 when you can, without peeking:

- [ ] List the top-level `data/` entries and say which **bucket** each is (project / gateway / operational).
- [ ] Make a UI change and **find the file it wrote** on disk with the `/tmp/marker` + `find -newer` trick.
- [ ] State the real 8.3 path shape for a view (`projects/<x>/com.inductiveautomation.perspective/views/...` + `resource.json`) and a config resource (`config/resources/<scope>/<module>/<type>/<name>/config.json`).
- [ ] Point at the on-disk file for a database connection, a PLC/device connection, and a tag definition, and explain why "it's all in git" follows.
- [ ] Explain **deployment modes** in one sentence (one config set, per-mode overrides selected at boot) and name what differs between the `local-development` and `production` `TimescaleDB` connection.
- [ ] Explain why `db/` and `.resources/` must **not** be committed.

## Stretch `[OPTIONAL]` — draft the `.gitignore`

You now know the operational bucket. Turn that knowledge into ignore patterns — the precursor to `.deployignore`, which the deploy part puts to work.

Draft a starter `.gitignore` for an Ignition project repo. Cover the **operational bucket**: the internal DB, tag value stores, caches, blob stores. Then compare with the shipped [`.gitignore`](../.gitignore). What did you miss? What did the shipped one miss?

Commonly forgotten: `config/resources/local/` and `config/local/` (instance identity), `*.gwbk` (backups), `*.modl` (module binaries), `config/ignition/tags/*.idb` (tag value stores inside the versioned config tree), `migration-log-*.md` (written by the gateway at commissioning).

> **This lab breaks two of those rules on purpose.** It deliberately tracks a throwaway seed identity under `config/local` and `resources/local` so fresh clones boot; `.gitignore` stops new churn. In a real repo, never commit them. (`services/config/resources/migration-log-202605211406.md` is tracked for the same historical reason: it is the log of the seed's one-time 8.1 to 8.3 conversion.)

---

# Part 2 — Build the file-based deploy

The file-based pattern, end-to-end across the three lab gateways.

The five steps:

1. **Developer commits** to `projects/<name>/` on a `feature/*` branch off `main`, then opens a PR into `main`.
2. **Runner checks out** the merged commit (after the PR merges into `main`). The bundled `github-runner` container handles this.
3. **Runner prunes** the working tree per `.deployignore` so lab-only files (READMEs, docs, scripts) don't pollute the gateway.
4. **Runner ships** the files into the target gateway container via `docker cp` (the runner is a container itself, so it reaches through the docker socket; test and production bind-mount `./gateways/<gw>/{projects,config}` on the host, which is how you'll *verify* what landed).
5. **Runner calls** `POST /data/api/v1/scan/{projects,config}` to make the gateway notice the change without a restart.

## The deploy, by hand, once (guided, ~15 min)

Edit a view in the shipped `example-project` and ship it to test by hand — this is exactly what `lab04-deploy.yml` automates. Because `local` bind-mounts `./projects/`, editing a file in your working tree *is* editing the local gateway's disk:

1. Change `projects/example-project/com.inductiveautomation.perspective/views/pages/overview/view.json`: find the label whose `"text"` is `"Run Control"` (the title of the top-left card) and make it `"Run Control v2"`.
2. Scan the **local** gateway — local sees the change via bind mount immediately; the scan tells it to notice:
   ```bash
   scripts/scan.sh
   ```
   Verify in a browser: open the project at <http://localhost:8088/data/perspective/client/example-project>. The top-left card now reads **RUN CONTROL V2** (the label renders upper case).
3. Copy the same change to **test** manually. Test started empty, so there is nothing to wipe — just copy the project over and scan:
   ```bash
   docker cp ./projects/. lab04-ignition-test:/usr/local/bin/ignition/data/projects/
   scripts/scan.sh test
   ```
   Verify at <http://localhost:8089/data/perspective/client/example-project>: the same view, the same **RUN CONTROL V2** title.

   > **Expect red `null` values on test.** You copied the project, not the gateway config: test has no tag provider, OPC connection or database yet, so every binding shows red / `null`. That is expected. The first real deploy in Part 2.3 ships `services/config/` too, and the values come alive.

   `lab04-deploy.yml` does one more thing before copying: it **wipes** `projects/` and `config/` on the target (sparing the entries `.deployignore` protects — `config/local/`, `config/resources/local/`, and the gateway-owned internal identity by name: `user-source/default/`, `user-source/opcua-module/`, `identity-provider/default/`), so a resource deleted in the repo disappears from the gateway too. You'll read that step line by line in the workflow anatomy below.
4. Inspect `.deployignore`. Notice it excludes `README.md`, `LICENSE`, the `.github/` directory, `docs/`, `scripts/`, the per-instance `services/config/resources/local/`, and the gateway-owned **internal** identity by name: `user-source/default/`, `user-source/opcua-module/`, `identity-provider/default/` (deploying those would overwrite the target's admin user — instant lockout). Identity resources you add yourself (database or AD user sources, SAML/OIDC providers) hold no password data and deploy normally, as does `security-properties` (permission policy — tracked and shipped). For each pattern, say **why the gateway shouldn't have that file**.

> **Leave the edit uncommitted for now.** Part 2.3 commits it together with the project you'll create there — that's the moment the repo catches up with what you hand-deployed.

The runner topology:

```
       ┌─────────────┐                ┌────────────────────────────────┐
       │  GitHub     │ ── polls ──▶   │  bundled runner (lab04-runner) │
       │  Actions    │                │   • shares /var/run/docker.sock│
       │             │ ◀── results ── │   • on the lab's compose net   │
       └─────────────┘                └────────────────────────────────┘
                                                  │
                                                  │ docker cp / docker exec
                                                  ▼
                                       ┌────────────────────────────────┐
                                       │ ignition-test  → gateways/test/  │
                                       │ ignition-production → gateways/production/ │
                                       └────────────────────────────────┘
```

The runner is a container, so it doesn't share the host filesystem with test/production — it reaches *inside* their containers with `docker cp` through the docker socket. But test and production bind-mount their `projects/` and `config/` to `./gateways/test/` and `./gateways/production/` on the host (gitignored, created by `setup.sh`), so **you can watch a deploy land**: `ls gateways/test/projects` shows exactly what CI shipped. Treat those dirs as read-only — editing them by hand defeats the pipeline. (Local is different again: it bind-mounts `./projects/` and `./services/config/` from the repo itself, so changes show up without any copy step.)

## Solo: wire the flow into GitHub Actions (~40 min, plus ~5 for the optional Part 2.5)

### Part 2.1 — Verify the runner is up (5 min)

The runner is already running as part of the compose stack. Confirm it:

```bash
docker compose ps github-runner
docker compose logs --tail 50 github-runner   # look for "Listening for Jobs"
```

In your fork on GitHub, *Settings → Actions → Runners* should show the runner online with the `self-hosted, lab04` labels. If it's not there:

- `RUNNER_REPO_URL` in `.env` must point at your fork (not the upstream).
- `RUNNER_GITHUB_PAT` in `.env` must be a real `repo`-scope PAT, not the placeholder — a bad token shows up as a **401** in `docker compose logs github-runner`. Fix it, then `docker compose up -d --force-recreate github-runner`.
- Restart it: `docker compose restart github-runner`.

### Part 2.2 — GitHub environments + secrets (10 min)

In your fork:

1. *Settings → Environments → New environment*: `lab04-gateway-test`.
2. Under that environment, *Add secret*: `IGNITION_API_KEY` = the `IGNITION_API_KEY_TEST` value from your `.env` (the **test gateway's** key, generated by `setup.sh`).
3. Repeat for `lab04-gateway-production` with `IGNITION_API_KEY_PRODUCTION` from `.env` (the **production gateway's** key).

> **API keys are per-gateway, not per-URL.** Each gateway only accepts *its own* key; the test key won't authenticate against production. The host ports (8089/8090) are just how *you* reach the UIs — the **runner** reaches the same gateways by their compose service names (`http://ignition-test:8088`, `http://ignition-production:8088`), which is why `IGNITION_URL`'s default differs from the host port.

You **don't** need to set `IGNITION_URL` or `IGNITION_CONTAINER` variables unless your runner topology differs from the lab's — the workflow defaults match the bundled runner.

### Part 2.3 — Ship to test via `main` (15 min)

1. Create a **new project named `sample-project`** on the local gateway, the way you always do in Ignition: Designer → New Project (or the gateway UI, Platform → Projects). Because local bind-mounts `./projects/`, the project lands in your working tree the moment the gateway saves it — `git status` shows it as an untracked `projects/sample-project/` folder. That folder is your deployable: no export, no file editing.
2. Create **one simple view** in that project in the Designer (any name — e.g. a label with your name on it) and save. In the *New View* dialog, tick **Page URL** and give it `/`: that makes the view the project's start page, so a browser can open it. That gives you something visible to recognize on the test gateway after the deploy.
3. Branch off `main` and commit it — together with the still-uncommitted height tweak from the deploy-by-hand, so the repo matches what's already on the local gateway:
   ```bash
   git switch main && git switch -c feature/add-sample-project
   git add projects/
   git commit -m "Add sample-project"
   git push -u origin feature/add-sample-project
   ```
4. On GitHub, open a PR **into `main`** (base repository: `<you>/cicd-for-ignition`, your fork, not the course repo). Watch [`lab04-ci.yml`](../../../.github/workflows/lab04-ci.yml) run on `ubuntu-latest` (free): yamllint, actionlint, shellcheck, ign-lint, `docker compose config`, JSON validity, `.deployignore` syntax, and the security-properties identity check.
5. Merge the PR into `main`. [`lab04-deploy.yml`](../../../.github/workflows/lab04-deploy.yml) fires because of the `paths:` filter (and only on `main`). Validation already ran on the PR — that's the gate — so the deploy goes straight to shipping.
6. Watch the workflow run. The interesting steps are **Ship projects and config into gateway container** (the `docker cp` half) and **Trigger gateway scan** (`POST /data/api/v1/scan/{projects,config}`). On the **first** deploy to a fresh gateway, the scan step restarts it once instead: the gateway booted before its `test` config mode was on disk, and Ignition picks its deployment mode at boot. Every later deploy scans hot, no restart.
7. Verify in http://localhost:8089 — Platform → Projects lists **`sample-project`**, and its view opens at <http://localhost:8089/data/perspective/client/sample-project> (the page URL `/` you set). The deploy-by-hand's **RUN CONTROL V2** title is there too, now via the pipeline, and this time with live values: the deploy shipped the gateway config as well. Then verify from the **host**: `ls gateways/test/projects` shows the deployed tree (test's `projects/` and `config/` bind-mount to `./gateways/test/`), so you can `cat` the exact files CI just shipped.
8. **Multi-project check.** The deploy step copies `./projects/.` (the whole directory), so your single merge deployed `example-project`, `packaging-site` **and** `sample-project` at once. The unit of deploy is the `projects/` tree, not a single project.

### Part 2.4 — Release to production via `main` + tag (10 min)

Cut a release the GitHub Flow way: tag the commit on `main` you want in production. The change is already on `main` (that's what deployed it to test), so there's nothing to merge — you just tag. The **tag** — not the push to `main` — is what ships to production.

```bash
git switch main && git pull
git tag lab04-v0.1.0
git push origin lab04-v0.1.0        # ← lab04-release.yml fires
```

> **`fatal: tag 'lab04-v0.1.0' already exists`?** Your fork copied every tag the upstream repo had at fork time. `git tag -l` shows what's taken — either take the next free number (`lab04-v0.1.1` works exactly the same), or delete the stale tag first: `git tag -d lab04-v0.1.0 && git push origin :refs/tags/lab04-v0.1.0`.

[`lab04-release.yml`](../../../.github/workflows/lab04-release.yml) fires on the tag. You only ever tag a commit that is already on `main` — it passed CI on its PR — so the release goes straight to shipping. Watch it run, then check http://localhost:8090 — the change you merged into main and just released should be visible on production. Host-side check works here too: `ls gateways/production/projects`. The push to `main` deployed to test on its own; the **tag** is what promotes to production, so production always runs a named, re-deployable version. That's also your rollback button: `lab04-release.yml`'s `workflow_dispatch` takes a tag input.

### Part 2.5 — Break a deploy on purpose (optional, ~5 min)

Cause one of these and read the workflow output:

- **Wrong API key.** Set garbage in `lab04-gateway-test`'s secret, re-run the deploy. The **Ship step succeeds** (`docker cp` doesn't care about keys), then the scan step gets a **401** and fails fast, naming the secret to check. The new files are on the gateway's disk, but no scan told it to load them: the gateway keeps running what it had and you can still log in. It only picks the files up at its next restart, so "disk" and "running" now disagree. *What's your recovery story?*
- **Stopped container.** `docker compose stop ignition-test`, then trigger a deploy. The **verify step fails fast** ("container is in state 'exited', expected 'running'") before any file moved — much better than failing halfway.

Then fix it and re-run (manual `workflow_dispatch` works too). The steps are idempotent, so the deploy converges.

For your chosen failure, write down: **symptom → state of the gateway → recovery → which workflow step should have caught it earlier?**

## Definition of done (part 2)

- [ ] The bundled runner shows **online** in your fork (`self-hosted, lab04`).
- [ ] Both GitHub environments (`lab04-gateway-test`, `lab04-gateway-production`) exist, each with an `IGNITION_API_KEY` secret.
- [ ] A push to **`main`** (merged PR) triggered `lab04-deploy.yml` and **the project you created** is on the **test** gateway (:8089).
- [ ] A `lab04-v*` tag on `main` triggered `lab04-release.yml` and that project is on the **production** gateway (:8090).
- [ ] You broke **one** deploy on purpose and can describe the failure mode and recovery.
- [ ] You can name the GitHub Flow routing (push to `main` → test, tag on `main` → production) and explain, in five steps, what the runner does between "merge" and "gateway reloaded."

## Stretch `[OPTIONAL]` — the `modules.json` puzzle

Gateway-level config (the contents of `services/config/`) ships the same way `projects/` does — both workflows `docker cp ./services/config/.`. But not every gateway change rides that path, and not every change a scan can apply:

- **Module enablement** lives in `services/modules.json` — a *sibling* of `services/config/`, **not under it**. The deploy workflows copy `./services/config/.`, so `modules.json` is **not shipped** by them; in this lab it's bind-mounted into all three gateways. Open `lab04-deploy.yml` and confirm the `docker cp` targets.
- Even with a new `modules.json` on the gateway, **a scan won't apply it** — module enable/disable needs a gateway **restart** (`docker compose restart ignition-test`), unlike views/config which hot-reload on scan.

So the question to chew on: why does copy + scan work beautifully for views and database connections, but not for modules? List everything else a scan could never apply (memory, Java args, module binaries…). What does that tell you about where the image-based deploy (Lab 05) earns its keep?

---

## Debrief

- What surprised you about the on-disk layout? Which bucket has the trickiest deploy story? (Hint: the one that *sometimes* needs a restart.)
- For your current customer's CI/CD: where does each bucket live, and which are versioned?
- What happens if the runner crashes mid-deploy? The `docker cp` is *not* atomic — what does the gateway do with a partially-copied project?
- What's the rollback story? GitHub Flow gives you two levers: revert a bad merge on `main` (re-deploys **test**), or re-deploy a known-good tag to **production** via `lab04-release.yml`'s `workflow_dispatch`. Which applies to which gateway, and why?
- Where would the self-hosted runner sit on your customer's network? What does it need access to that GitHub-hosted runners don't have?

> **Next:** baking this into images is Lab 05. Bring your `modules.json` stretch answer.
