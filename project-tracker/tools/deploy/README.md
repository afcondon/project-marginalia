# Marginalia deploy — MBP → MacMini

A proven, repeatable push-button deploy. Edit on the MBP, push to GitHub,
`make deploy`. The MacMini (`andrews-mac-mini`) is the canonical always-on host.

## Use

```bash
# from project-tracker/ on the MBP
git commit -am "…" && git push      # deploy ships origin/main, not your working tree
make deploy                         # mini pulls, builds, restarts, health-checks
make deploy-check                   # report the mini's state, change nothing
```

## What it does

`deploy.sh` (MBP) → scp's `remote-deploy.sh` to the mini → ssh-runs it. The mini:

1. `git fetch`; reconcile the checkout to `origin/main`
   (clean fast-forward, or a guarded `reset --hard` — see Safety);
2. `npm install` (host-local `node_modules`, incl. the duckdb native binding);
3. `npm run build:server` (spago → `output/`) and `npm run bundle:frontend`;
4. restart the **api** (:3100) and **frontend** (:3101) LaunchAgents
   (`launchctl kickstart -k gui/$UID/<label>`);
5. health-check both ports (polls ~60s to ride out launchd backoff).

The mini builds host-native from source — nothing large crosses the wire. The
current `remote-deploy.sh` is shipped every run, so the mini never executes a
stale copy of the deploy logic even when its checkout is behind.

## Topology

| | |
|---|---|
| Host | `andrew@andrews-mac-mini` |
| Checkout | `/Users/andrew/work/marginalia-demo/project-tracker` (git root one level up) |
| Remote | `git@github.com:afcondon/project-marginalia.git`, branch `main` |
| Services | api :3100, frontend :3101, whisper :3200 (whisper is **not** touched — separate Python service) |
| Build artifacts | `node_modules/`, `output/`, `frontend/public/bundle.js` — all gitignored, built on the host |
| Host config | `.env` (untracked) — never touched by deploy |

Override with `MARGINALIA_DEPLOY_HOST`, `MARGINALIA_REMOTE_DIR`, `DEPLOY_BRANCH`.

## Safety

- Deploy ships `origin/main`. `deploy.sh` refuses if local `main` has unpushed
  commits.
- The mini reconcile uses `git reset --hard origin/main` **only** when the tree
  is dirty/non-fast-forward **and** has **zero local commits ahead** of origin
  (nothing unique to lose). Otherwise it's a clean fast-forward. If the checkout
  is ever ahead of origin, the script refuses and asks for a manual resolve.
- Before any reset, a diff vs `origin/main` is saved to
  `/tmp/marginalia-predeploy-<timestamp>.patch` on the mini.
- `.env` and other untracked host files (`output.bak*`, etc.) are never removed
  — `reset --hard` only rewrites tracked files.
- Builds happen **before** restarts: a failed build leaves the running services
  untouched on their previous artifacts.

## Rollback

`git revert` (or reset) on the MBP, push, `make deploy` again. The mini always
converges to whatever `origin/main` is.
