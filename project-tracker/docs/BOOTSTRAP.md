# Fresh-install bootstrap

How to stand up a Marginalia instance on a new machine from a clean clone.
The author's own MBP instance uses defaults that preserve its pre-existing
setup; everything in this doc is about the "second machine" case —
typically a MacMini on the tailnet running demo data for screen recordings
or phone-client testing.

## What you need on the new machine

- macOS (launchd + plist assumptions below are macOS-specific)
- `node` ≥ 18 (via nvm or otherwise), `npm`
- `python3` (only if you want the whisper voice-note sidecar)
- `git`
- Tailscale installed and logged into the tailnet

## Clone + build

```bash
cd ~/work
git clone https://github.com/afcondon/project-marginalia.git marginalia-demo
cd marginalia-demo/project-tracker
npm install
npm run bootstrap
```

`npm install` pulls in the PureScript toolchain (`purescript` and `spago`
are committed as devDependencies), and `npm run bootstrap` compiles the
server's PureScript modules into `output/` and bundles the frontend to
`frontend/public/bundle.js`. Both of those directories are gitignored —
they don't travel with the clone — so the bootstrap step is required on
every fresh machine. Incremental rebuilds after the first bootstrap are
fast.

The locally-installed toolchain lives at `node_modules/.bin/spago` and
`node_modules/.bin/purs`; npm scripts pick them up automatically. You
don't need a global install.

## Optional: `.env` for per-machine overrides

Marginalia reads a `.env` file at the repo root on startup (see
`tools/launchd/start-api.sh`). The only setting you're likely to want:

```
# .env — not committed; created per clone
MARGINALIA_ATTACHMENT_STORE=/Users/afc/marginalia-attachments/
```

The trailing slash matters. When set, the server:

1. Treats this directory as the canonical attachment store
2. Translates attachment file paths under this prefix to `/attachments/...`
   URLs for the browser

If you leave `.env` out entirely, the server falls back to the MBP's
existing `/Volumes/Crucial4TB/Documents/Notes Attachments/` default,
which is harmless on any machine that doesn't have that drive mounted —
attachments just won't resolve to URLs until you configure the env var.

On a fresh demo box, create the directory and symlink the frontend's
`public/attachments` to it so the browser can load attachment files:

```bash
mkdir -p ~/marginalia-attachments
ln -sf ~/marginalia-attachments frontend/public/attachments
```

## Install the LaunchAgents

```bash
./tools/launchd/install.sh            # api + frontend
./tools/launchd/install.sh --with-whisper  # also voice-note sidecar
```

The committed plist files use `__PROJECT_ROOT__` and `__HOME__`
placeholders; `install.sh` substitutes them for the current clone's
absolute path and the current user's home directory at install time. The
scripts under `tools/launchd/start-*.sh` also resolve the project root
from their own script location, so the same files work from any clone
path without editing.

After `install.sh` completes, verify the services are running:

```bash
launchctl list | grep marginalia
curl -s -o /dev/null -w "api: %{http_code}\n" http://localhost:3100/api/projects
curl -s -o /dev/null -w "frontend: %{http_code}\n" http://localhost:3101/
```

The first GET against the API triggers the schema bootstrap: the server
reads `database/schema.sql` at startup and runs it against whatever DB
file is sitting at `database/tracker.duckdb`. Every statement in the
schema is idempotent (`CREATE TABLE IF NOT EXISTS`, `ALTER TABLE ADD
COLUMN IF NOT EXISTS`, etc.), so re-running is safe. On a fresh clone the
file doesn't exist yet, so DuckDB creates it and the schema lands on
first boot. No separate migration step is required.

## Seed fictional demo data

```bash
node scripts/seed-demo-data.mjs
```

This POSTs ~25 fictional projects across all six domains via the local
API. Refuses to run if the target already has ≥3 projects (pass
`--force` to override). Against a remote target, set `MARGINALIA_API`:

```bash
MARGINALIA_API=https://macmini.tailnet.ts.net node scripts/seed-demo-data.mjs
```

The seed includes a coherent "maker working across many domains" cast —
Programming, Music, House, Woodworking, Garden, and Infrastructure
projects — with parent/child relationships, varied descriptions, tags, a
mix of statuses, and representative blog classifications (`wanted`,
`drafted`, and one `published`). Enough content to make every feature
of the Register visible on first load.

## Expose via Tailscale Serve

Three Tailscale Serve commands give you a single-origin HTTPS endpoint:

```bash
tailscale serve --bg --https=443 / http://127.0.0.1:3101
tailscale serve --bg --https=443 /api/ http://127.0.0.1:3100
tailscale serve --bg --https=443 /transcribe http://127.0.0.1:3200
```

On macOS, the Tailscale CLI often isn't on `PATH` out of the box when
Tailscale is installed from the Mac App Store or official installer
(rather than Homebrew). The actual binary lives at
`/Applications/Tailscale.app/Contents/MacOS/Tailscale`. Either add it to
`PATH` in your shell profile, or create a symlink once:

```bash
sudo ln -sf /Applications/Tailscale.app/Contents/MacOS/Tailscale /usr/local/bin/tailscale
```

After that the `tailscale` commands above just work from any shell.

After which `https://<hostname>.<tailnet>.ts.net/` reaches the frontend,
and the frontend's bundle automatically uses the same origin for its API
and whisper calls because the smart-URL detection in `API.js` and
`App.js` checks `window.location.hostname`. From `localhost` it keeps
talking to ports 3100/3200; from anywhere else it talks to same-origin
`/api/*` and `/transcribe`.

No rebuild needed — the same committed bundle works in both deployment
shapes.

## Uninstall / teardown

```bash
./tools/launchd/uninstall.sh
```

Removes the launchd plists and stops all three services. The DB file
and any attachments you created are left in place; delete
`database/tracker.duckdb` by hand if you actually want to wipe the demo
data.
