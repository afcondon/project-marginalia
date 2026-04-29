# SDI compatibility checklist

When you add a new web service to the marginalia registry that's
meant to be lazy-spawned by SDI, walk this list. If any item isn't
satisfied, SDI will silently skip the entry (logged as
"`startCommand has no literal :PORT`" or "`PORT already bound`") and
the service falls back to whatever manual lifecycle you'd set up
otherwise.

## The contract

SDI binds the registered port at boot, holds it idle, and on first
request it:

1. Picks a free **internal port** (typically `2`-prefixed: 3060 →
   23060).
2. Runs the registered `startCommand` after substituting every
   `\b<publicPort>\b` literal with the internal port.
3. Waits for the process to bind the internal port.
4. Proxies the public-port traffic to the internal port.
5. SIGTERMs the backend after 10 minutes of idleness.

## Checklist for a new service

### 1. Server reads its port from an env var (or CLI flag)

The port can't be a hardcoded literal in the source. SDI's only knob
is the registered startCommand string — if the source ignores the
environment, SDI's port-rewrite has nowhere to land.

PureScript / HTTPurple example (see `purescript-playground/server/src/Playground/Server/Main.purs`):

```purescript
resolvePort :: Effect Int
resolvePort = do
  raw <- Process.lookupEnv "BACKEND_PORT"
  pure case raw >>= Int.fromString of
    Just p -> p
    Nothing -> 3050   -- sane default for direct `node server/run.js`

main :: ServerM
main = do
  port <- liftEffect resolvePort
  serveOn port
```

Pattern: env-or-default. Direct invocations still work; SDI just
overrides via env.

### 2. The registered `startCommand` contains the literal public port

SDI uses a regex `\b<port>\b` to find what to rewrite. Examples:

- ✅ `cd /abs/path && BACKEND_PORT=3060 node server/run.js`
- ✅ `cd /abs/path && npx http-server public -p 3061 -c-1 --cors`
- ❌ `cd /abs/path && make start` (the port is hidden inside the Makefile)
- ❌ `cd /abs/path && node server/run.js` (no port at all)

### 3. Each role gets its own server entry with its own startCommand

A single project commonly registers `api` and `frontend` rows. Each
has its own port and SDI binds them independently. Don't have one
spawn launch both — that defeats lazy-spawn for the second role
(SDI sees that port as already bound and skips).

If your project has a `make start` that brings up everything together,
split the command per role for the SDI registration:

```
api:      cd /abs && BACKEND_PORT=3060 node server/run.js
frontend: cd /abs && npx http-server public -p 3061 -c-1 --cors
```

`make start` itself can stay as-is for direct human use; the marginalia
registration is a separate channel.

### 4. Absolute paths

`startCommand` runs from SDI's cwd. Always `cd /absolute/path && ...`.
The same lesson applies to any `--config /relative/path` flags inside
the command — make them absolute.

### 5. Build artefacts must already exist on disk

SDI doesn't run `make build` or `spago bundle` for you. Bundles, output
trees, etc. need to be present from a prior build pass. CI / onboarding
should run `make bootstrap` (or equivalent) once.

## Handing off to SDI

After registering a compatible entry in marginalia:

```
# free the port if a manual server is bound to it
make stop      # or kill -TERM <pid>

# tell SDI to rescan the registry
kill -HUP $(pgrep -f 'node router.mjs')

# verify
tail -10 ~/Library/Logs/sdi/router.log
lsof -nP -iTCP -sTCP:LISTEN | grep :<port>
```

Expect a log line like
`[sdi] :NNNN → ProjectName (project ID) — listening, idle`. First hit
to the URL spawns the backend (cold start typically 300-500ms for a
PureScript HTTPurple service).

## Symptoms of a non-compliant entry

| Symptom | Likely cause |
|---|---|
| SDI log: `startCommand has no literal :PORT` | port not in command — see #2 |
| SDI log: `:PORT already bound by another process` | manual server still running |
| Cold spawn never completes | server doesn't read the env var, binds the wrong port |
| Frontend serves but its API calls 502 | api spawn binds wrong port; check #1 |

## Reviewing SDI compliance for new work

When you ship a new web service, before celebrating:

```
[ ] Server reads port from env (or CLI flag)
[ ] Registered startCommand has literal port
[ ] Each role has its own startCommand
[ ] Absolute paths everywhere
[ ] Build artefacts exist on disk
[ ] Manual server stopped, SIGHUP sent, lazy-spawn verified
```
