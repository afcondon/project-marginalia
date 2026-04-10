# MacMini session briefing

Prepared by a Claude session on the MBP (2026-04-10). Pick this up
on the MacMini via `ssh andrew@100.101.177.83` + tmux + Claude.

## What exists on the MacMini

- **Clone**: `~/work/marginalia-demo` (branch: `capture-pwa`)
- **Working directory**: `~/work/marginalia-demo/project-tracker`
- **Node**: v22.18.0 at `/usr/local/bin/node` — NOT on default PATH for non-interactive shells, always prefix commands with `export PATH=/usr/local/bin:$PATH`
- **Python**: system python3 is 3.9.6 — **too old for whisper** (needs 3.13 per the existing start-whisper.sh)
- **Tailscale**: installed as Mac app at `/Applications/Tailscale.app/Contents/MacOS/Tailscale`; the mini is `andrews-mac-mini` at `100.101.177.83`
- **Tailscale Serve**: configured to expose port 3101 on HTTPS at `https://andrews-mac-mini.vaquita-paradise.ts.net/`

### Running services (LaunchAgents)

| Service | Port | Status |
|---------|------|--------|
| API (HTTPurple/DuckDB) | 3100 | running |
| Frontend (Node proxy server) | 3101 | running |
| Whisper sidecar | 3200 | **NOT installed** — needs Python 3.13 |

- Logs: `~/Library/Logs/marginalia/`
- LaunchAgent plists: `~/Library/LaunchAgents/net.hylograph.marginalia.*.plist`
- Install/uninstall: `./tools/launchd/install.sh [--with-whisper]`

### Database

- Fresh DuckDB at `~/work/marginalia-demo/project-tracker/database/tracker.duckdb`
- Schema bootstrapped at server startup (no migrate step needed)
- Seeded with 29 fictional demo projects via `scripts/seed-demo-data.mjs`
- `.env` file: `MARGINALIA_ATTACHMENT_STORE=/Users/andrew/marginalia-attachments/`
- Attachment symlink: `frontend/public/attachments -> ~/marginalia-attachments`

### URLs

| What | URL |
|------|-----|
| Desktop Register (demo) | https://andrews-mac-mini.vaquita-paradise.ts.net/ |
| Capture PWA | https://andrews-mac-mini.vaquita-paradise.ts.net/capture/ |
| API (via proxy) | https://andrews-mac-mini.vaquita-paradise.ts.net/api/projects |
| API (local) | http://localhost:3100/api/projects |
| Frontend (local) | http://localhost:3101/ |

## Task 1: Get whisper running

The whisper sidecar (`tools/whisper-server.py`) is a small Python HTTP
server that accepts `POST /transcribe` with `audio/webm` and returns
`{"text": "transcribed text"}` using OpenAI's Whisper model.

### What the start script expects

```bash
# tools/launchd/start-whisper.sh
export PATH="/Library/Frameworks/Python.framework/Versions/3.13/bin:$PATH"
python3 tools/whisper-server.py
```

It expects Python 3.13 at a specific path. On the MacMini, system
python is 3.9.6. You need to install Python 3.13.

### Installation options

1. **python.org installer** (recommended for matching the MBP's setup):
   Download from https://www.python.org/downloads/ — the macOS universal
   installer puts python3.13 at `/Library/Frameworks/Python.framework/Versions/3.13/bin/python3`.

2. **Homebrew**: `brew install python@3.13` — but the Mini doesn't have
   Homebrew installed.

3. **pyenv**: if you prefer — but adds another tool to manage.

### After Python 3.13 is available

```bash
cd ~/work/marginalia-demo/project-tracker

# Check what dependencies whisper-server.py needs
head -30 tools/whisper-server.py

# Install them (likely: openai-whisper, flask or http.server)
pip3.13 install openai-whisper

# Test it directly
python3.13 tools/whisper-server.py
# → should listen on :3200

# If it works, install the LaunchAgent
./tools/launchd/install.sh --with-whisper
```

Check the whisper-server.py imports to see the exact deps. The MBP
version uses the `whisper` package (OpenAI's open-source model, runs
locally on CPU/GPU — no API key needed). On the Mini's Apple Silicon,
inference is fast enough for short clips.

### Verifying whisper works

```bash
# From the Mini itself:
curl -X POST http://localhost:3200/transcribe \
  -H 'Content-Type: audio/webm' \
  --data-binary @some-test-file.webm

# Should return: {"text": "whatever was said in the audio"}
```

Once whisper is listening on :3200, the frontend proxy already routes
`/transcribe` to it, so the Capture PWA's Dictate button will work
from the phone without any code changes.

## Task 2: Iterate on the Capture PWA

The capture app source is at `capture/` in the project-tracker
directory. It's a PureScript/Halogen app that builds with:

```bash
export PATH=/usr/local/bin:$PATH
cd ~/work/marginalia-demo/project-tracker
npm run bundle:capture
```

After rebuilding, the frontend server picks up the new bundle
automatically (no restart needed — cache-control: no-cache).

### Current state

- Project picker: works, fetches from /api/projects
- Write flow: works (saves as note via POST)
- URL flow: works (saves as note via POST)
- Dictate flow: **blocked on whisper** — recording works, but
  transcription POST to /transcribe fails with no listener
- Photo flow: not yet built — needs a multipart upload endpoint
  on the server (POST /api/agent/projects/:id/attachments/upload)

### Files to know

| File | Purpose |
|------|---------|
| `capture/src/App.purs` | Main Halogen component — all UI + state |
| `capture/src/App.js` | FFI: audio recording, localStorage |
| `capture/src/API.purs` | HTTP client (fetchProjects, addNote) |
| `capture/src/API.js` | FFI: JSON escaping |
| `capture/public/styles.css` | All CSS — iPhone-first, dense/serif |
| `capture/public/index.html` | HTML shell + PWA meta tags |
| `capture/public/manifest.json` | PWA manifest |

### Design philosophy

This is a **capture-first** app, not a browser. Four verbs: dictate,
write, URL, photo. One screen. No navigation. Projects are selected
via a bottom-sheet picker and remembered in localStorage. Recent
captures appear as a confirmation list. The desktop Register/Dossier
is for thinking; this app is for catching.

The user has sharp vision and prefers small, dense text. The CSS uses
13px base, 9-11px labels, Old Standard TT serif for project names,
Libre Franklin for everything else. Paper/sepia background.

## Task 3: Photo capture (needs server work)

The current attachment endpoint (`POST /api/agent/projects/:id/attachments`)
only registers a filesystem path — it assumes the file already exists
on the server's disk. For phone photo capture, the file has to travel
from the phone to the server.

New endpoint needed:

```
POST /api/agent/projects/:id/attachments/upload
Content-Type: multipart/form-data
  file: <binary>
  description: <optional text>
```

The endpoint should:
1. Read the uploaded file from the multipart body
2. Generate a unique filename (timestamp + original name)
3. Write to `$MARGINALIA_ATTACHMENT_STORE/<filename>`
4. Create an attachment row in DuckDB (same schema as existing)
5. Return the same JSON shape as the existing attachment endpoint

HTTPurple (the server framework) can parse multipart bodies — check
its docs or the existing codebase for patterns. The server source is
at `server/src/`.

## Git state

- Branch: `capture-pwa` (not yet merged to main)
- Remote: `https://github.com/afcondon/project-marginalia.git`
- The MBP also has this branch checked out; push/pull to coordinate

## Marginalia skill

If you need to understand the full API surface, port registry, status
lifecycle, etc., load the marginalia skill from
`~/.claude/skills/marginalia.md` (symlinked to the repo copy at
`.claude/skills/marginalia.md`).

**Note**: the skill symlink may not exist on the MacMini. You can
read the skill directly from the repo at:
`~/work/marginalia-demo/project-tracker/.claude/skills/marginalia.md`
