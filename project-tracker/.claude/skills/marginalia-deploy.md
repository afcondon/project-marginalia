---
name: marginalia-deploy
description: Deploy Marginalia (the project tracker) from the MBP to the canonical MacMini host. Use when asked to deploy/ship/release Marginalia, push frontend or server changes live, or update andrews-mac-mini after editing project-tracker. Push-button — runs build + restart + health-check on the mini.
---

# Marginalia deploy — MBP → MacMini

Marginalia's canonical host is the **MacMini** (`andrews-mac-mini`), running
three LaunchAgents: api (:3100), frontend (:3101), whisper (:3200). You develop
on the **MBP** and deploy with one command. This skill is the authoritative,
proven path — do **not** hand-scp files, hand-run `git pull`, or restart agents
ad hoc.

## The workflow

```bash
cd /Users/afc/work/afc-work/agent-teams/project-tracker   # on the MBP
git commit -am "…"
git push                       # deploy ships origin/main, NOT your working tree
make deploy                    # mini: pull → build → restart → health-check
```

To inspect the mini's state without changing anything:

```bash
make deploy-check
```

Both wrap `tools/deploy/deploy.sh` (see `tools/deploy/README.md` for the full
description). `make deploy` ssh's to the mini, ships the current deploy logic,
reconciles the checkout to `origin/main`, rebuilds host-local artifacts
(`node_modules` incl. the duckdb native binding, spago `output/`, the frontend
`bundle.js`), restarts the **api** and **frontend** agents, and health-checks
both ports.

## Key facts

- **Deploy ships `origin/main`** — commit *and push* first, or `make deploy`
  refuses (it guards against unpushed commits).
- **Build is frontend- or server-agnostic**: both are rebuilt each run; spago is
  incremental, so server-only-unchanged deploys are cheap.
- **whisper (:3200) is not touched** — separate Python service.
- **`.env` on the mini is untracked host config and is never modified.**
- **Reconcile safety**: the mini uses `git reset --hard origin/main` only when
  its tree is dirty/non-fast-forward *and* has zero local commits ahead (a
  pre-reset diff is saved to `/tmp/marginalia-predeploy-*.patch`). If the mini's
  checkout is ever *ahead* of origin, deploy refuses — resolve by hand.

## Topology

| | |
|---|---|
| Host / login | `andrew@andrews-mac-mini` |
| Checkout | `/Users/andrew/work/marginalia-demo/project-tracker` |
| Remote / branch | `git@github.com:afcondon/project-marginalia.git` / `main` |
| Restart | `launchctl kickstart -k gui/501/net.hylograph.marginalia.{api,frontend}` |
| Logs | `~/Library/Logs/marginalia/{api,frontend}.log` on the mini |

## When something looks wrong

- `make deploy-check` first — it prints `ahead/behind/dirty` and the SHAs.
- A failed build leaves services running on the previous artifacts (build runs
  before restart), so a bad push won't take the site down — fix forward and
  redeploy.
- Rollback = `git revert`/reset on the MBP, push, `make deploy` again. The mini
  always converges to `origin/main`.

## Exposing as a slash command (one-time, optional)

Like `/marginalia` and `/what-next`, this can be symlinked so Claude Code picks
it up as `/marginalia-deploy`:

```bash
ln -s /Users/afc/work/afc-work/agent-teams/project-tracker/.claude/skills/marginalia-deploy.md \
      ~/.claude/commands/marginalia-deploy.md
```
