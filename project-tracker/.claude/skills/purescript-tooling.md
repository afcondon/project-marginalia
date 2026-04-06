# PureScript Tooling Skill

You are configuring, building, or debugging PureScript project infrastructure. This skill covers spago, package sets, workspaces, bundling, npm integration, and FFI file layout.

---

## Spago (Build Tool & Package Manager)

Spago is the standard PureScript build tool. It manages dependencies, builds, bundles, and runs tests.

### Package Set Model

PureScript uses a **curated package set** (not individual version resolution like npm/cargo). The package set pins every package to a specific compatible version. You declare which packages you need; the set provides the versions.

```yaml
# Workspace root spago.yaml — declares which package set to use
workspace:
  packageSet:
    registry: 73.3.0   # <-- package set version from the PureScript registry
  extraPackages: {}     # <-- for local or git packages not in the registry
```

**CRITICAL**: The workspace root MUST have `packageSet`. Without it, spago cannot resolve any dependencies.

### Dependency Syntax

Dependencies are **bare package names only**. No version ranges, no semver constraints. The package set handles versions.

```yaml
# WRONG — spago does not accept version ranges
dependencies:
  - aff: ">=8.0.0 <9.0.0"
  - halogen: ">=7.0.0 <8.0.0"

# RIGHT — bare names only
dependencies:
  - aff
  - halogen
  - prelude
  - effect
```

This is the single most common mistake when generating spago.yaml files. Never add version constraints to dependencies.

### Workspace Structure (Multi-Package Projects)

Real projects typically have a workspace with multiple packages (e.g., server + frontend). The root spago.yaml is the workspace; subdirectories contain packages.

```
my-project/
├── spago.yaml              # workspace root (packageSet, extraPackages)
├── server/
│   ├── spago.yaml           # package definition (name, dependencies)
│   └── src/
│       └── Main.purs
├── frontend/
│   ├── spago.yaml           # package definition (name, dependencies, bundle config)
│   └── src/
│       └── Main.purs
└── shared/                  # optional shared package
    ├── spago.yaml
    └── src/
```

**Workspace root** (spago.yaml):
```yaml
workspace:
  packageSet:
    registry: 73.3.0
  extraPackages: {}
```

**Server package** (server/spago.yaml):
```yaml
package:
  name: my-server
  description: "Server package"
  dependencies:
    - aff
    - console
    - effect
    - httpurple
    - prelude
```

**Frontend package with bundle config** (frontend/spago.yaml):
```yaml
package:
  name: my-frontend
  description: "Frontend package"
  bundle:
    module: MyApp.Main        # entry point module
    outfile: public/bundle.js # output path (relative to package dir)
    platform: browser         # browser | node
  dependencies:
    - aff
    - halogen
    - prelude
    - effect
    - web-dom
    - web-html
```

### Extra Packages (Local & Git Dependencies)

For packages not in the registry (local workspace packages, forks, unpublished libraries):

```yaml
workspace:
  packageSet:
    registry: 73.3.0
  extraPackages:
    # Local path dependency (sibling repo):
    hylograph-prim-zoo-mosh:
      path: "../../purescript-hylograph-showcases/psd3-prim-zoo-mosh"

    # Git dependency:
    my-fork:
      git: "https://github.com/user/purescript-my-fork.git"
      ref: "v1.0.0"
      subdir: "."
      dependencies:
        - prelude
        - effect
```

Workspace packages (packages defined in subdirectories of the same workspace) are automatically discovered. You do NOT need to list them in extraPackages.

---

## Build Commands

```bash
# Build everything in the workspace
spago build

# Build a specific package
spago build -p my-server

# Bundle frontend for browser (uses bundle config from spago.yaml)
spago bundle -p my-frontend

# Run a package's main
spago run -p my-server

# Run tests
spago test
spago test -p my-server

# Install dependencies (usually not needed — build does this)
spago install

# Generate lockfile (spago does this automatically on first build)
# The lockfile (spago.lock) should be committed to git
```

### Build Output

Compiled output goes to `output/` at the workspace root (not per-package). This directory:
- Contains one subdirectory per module (e.g., `output/Data.Array/`)
- Is needed by the PureScript language server (cclsp) for code intelligence
- Should be gitignored
- Is shared across all packages in the workspace

---

## Module Naming & File Paths

Module name must match file path exactly:
- `module Foo.Bar.Baz` → `src/Foo/Bar/Baz.purs`
- `module MyApp.Component.App` → `src/MyApp/Component/App.purs`
- `module Test.Main` → `test/Test/Main.purs`

In a workspace, each package has its own `src/` directory. The module namespace should reflect the package:
- `server/src/ProjectTracker/Server/Main.purs` → `module ProjectTracker.Server.Main`
- `frontend/src/ProjectTracker/Main.purs` → `module ProjectTracker.Main`

---

## FFI File Placement

JavaScript FFI files must be **alongside their corresponding PureScript file** with the same base name:

```
src/
├── Database/
│   ��── DuckDB.purs     # PureScript module with `foreign import` declarations
│   └── DuckDB.js       # JavaScript implementations (same directory, same name)
```

The JS file must use ES module syntax:
```javascript
// DuckDB.js
export const myFunction = (arg) => { ... };
export function myOtherFunction(arg) { return ... ; }
```

**Common mistakes**:
- Putting FFI files in a separate `ffi/` directory (won't be found)
- Using CommonJS (`module.exports`) instead of ES modules (`export`)
- Naming the JS file differently from the PureScript file

---

## npm Integration

PureScript projects that use FFI typically need npm packages. The `package.json` goes at the workspace root.

```json
{
  "name": "my-project",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "scripts": {
    "build": "spago build",
    "build:server": "spago build -p my-server",
    "build:frontend": "spago build -p my-frontend",
    "bundle:frontend": "spago bundle -p my-frontend",
    "serve:api": "node server/run.js",
    "serve:frontend": "npx http-server frontend/public -p 3100"
  },
  "dependencies": {
    "duckdb": "^1.4.4"
  }
}
```

**IMPORTANT**: Set `"type": "module"` for ES module support (required by PureScript's compiled output).

### Server Entry Point

Spago compiles to `output/` but doesn't create a runnable entry point. Create a small JS file:

```javascript
// server/run.js
import { main } from "../output/MyApp.Server.Main/index.js";
main();
```

---

## HTTPurple Server Setup

The standard PureScript HTTP server framework. Key dependency: `httpurple`.

### Route Pattern (Discriminated Union + Routing Duplex)

```purescript
import HTTPurple (serve, ok, ok', notFound)
import Routing.Duplex as RD
import Routing.Duplex.Generic as RDG

-- Routes as a data type
data Route
  = ListItems
  | GetItem
  | CreateItem
  | Stats

-- Bidirectional route definitions
route :: RD.RouteDuplex' Route
route = RD.root $ RDG.sum
  { "ListItems":  RD.path "api/items" RD.noArgs
  , "GetItem":    RD.path "api/items" (RD.int RD.segment)
  , "CreateItem": RD.path "api/items" RD.noArgs
  , "Stats":      RD.path "api/stats" RD.noArgs
  }

-- Dispatch
router { route: ListItems, method: Get } = ok "items list"
router { route: Stats, method: Get }     = ok "stats"
router _                                  = notFound

-- Server startup
main :: Effect Unit
main = serve { port: 3000 } { route, router }
```

### CORS Headers (Common Need)

```purescript
import HTTPurple.Headers (headers)

corsHeaders :: Headers
corsHeaders = headers
  { "Access-Control-Allow-Origin": "*"
  , "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS"
  , "Access-Control-Allow-Headers": "Content-Type"
  }
```

---

## DuckDB FFI Pattern (From Minard)

For Node.js servers that use DuckDB:

**npm dependency**: `"duckdb": "^1.4.4"`

**PureScript types** (Database/DuckDB.purs):
```purescript
module Database.DuckDB where

import Effect (Effect)
import Effect.Aff (Aff)
import Control.Promise (Promise, toAffE)
import Foreign (Foreign)

foreign import data Database :: Type

foreign import openDBImpl :: String -> Effect (Promise Database)
foreign import queryAllImpl :: Database -> String -> Effect (Promise (Array Foreign))
foreign import execImpl :: Database -> String -> Effect (Promise Unit)

openDB :: String -> Aff Database
openDB path = toAffE (openDBImpl path)

queryAll :: Database -> String -> Aff (Array Foreign)
queryAll db sql = toAffE (queryAllImpl db sql)

exec :: Database -> String -> Aff Unit
exec db sql = toAffE (execImpl db sql)
```

**JavaScript implementation** (Database/DuckDB.js):
```javascript
import duckdb from "duckdb";

export const openDBImpl = (path) => () =>
  new Promise((resolve, reject) => {
    const db = new duckdb.Database(path, (err) => {
      if (err) reject(err);
      else resolve(db);
    });
  });

export const queryAllImpl = (db) => (sql) => () =>
  new Promise((resolve, reject) => {
    db.all(sql, (err, rows) => {
      if (err) reject(err);
      else resolve(rows || []);
    });
  });

export const execImpl = (db) => (sql) => () =>
  new Promise((resolve, reject) => {
    db.run(sql, (err) => {
      if (err) reject(err);
      else resolve();
    });
  });
```

Key points:
- Use `Effect (Promise a)` on the PS side, `toAffE` to convert to `Aff`
- JS functions are curried (one arg at a time, each returning `() => ...` for the Effect thunk)
- The `duckdb` npm package uses callback-style; wrap in Promise
- For parameterized queries, use `EffectFn3` with `(db, sql, params)` to avoid currying overhead

---

## Halogen Frontend Setup

### Minimal Main.purs

**CRITICAL**: Use `selectElement` to mount into a specific `#app` div, NOT `awaitBody`. Using `awaitBody` mounts the Halogen app as a child of `<body>`, which renders it AFTER the `<div id="app">` and `<script>` tags — pushing the app below the fold. This is the ONE stringly-typed thing in the PureScript stack and a frequent point of failure.

```purescript
module MyApp.Main where

import Prelude
import Data.Maybe (Maybe(..))
import Effect (Effect)
import Effect.Class (liftEffect)
import Effect.Exception (throw)
import Halogen.Aff (awaitLoad, selectElement, runHalogenAff)
import Halogen.VDom.Driver (runUI)
import Web.DOM.ParentNode (QuerySelector(..))
import MyApp.Component.App as App

main :: Effect Unit
main = runHalogenAff do
  awaitLoad
  mEl <- selectElement (QuerySelector "#app")
  case mEl of
    Nothing -> liftEffect $ throw "Could not find #app element"
    Just el -> void $ runUI App.component unit el
```

The `awaitBody` pattern is only appropriate when there is no `<div id="app">` in the HTML and you want Halogen to own the entire `<body>`. When index.html has `<div id="app"></div>` (which is standard), always use `selectElement`.

### Bundle and Serve

```bash
# Bundle (uses config from frontend/spago.yaml)
spago bundle -p my-frontend

# Serve static files
npx http-server frontend/public -p 3100

# Or use Python's built-in server
python3 -m http.server 3100 -d frontend/public
```

The bundle output path is set in `spago.yaml` under `bundle.outfile`. The HTML file should reference it:
```html
<script type="module" src="bundle.js"></script>
```

---

## Common Spago Errors

### "No workspace configuration found"
You're not in a directory with a workspace-level `spago.yaml`, or the file is missing `workspace:`.

### "Package not found in package set"
The package name is misspelled or not in the registry version you specified. Check the PureScript registry or try a newer package set version.

### "Could not resolve dependencies"
Usually means two packages require incompatible versions. Fix by:
1. Updating the package set version
2. Adding a specific version override in `extraPackages`

### Build succeeds but bundle fails
Check that:
- The `bundle.module` matches an actual module name
- The module has a `main` function (for `platform: node`) or just exists (for `platform: browser`)
- The `bundle.outfile` directory exists

---

## .gitignore for PureScript Projects

```gitignore
# Spago / PureScript
output/
.spago/
.psci_modules/
node_modules/

# Bundle output (regenerated)
frontend/public/bundle.js

# DuckDB files (generated, often large)
*.duckdb
*.duckdb.wal

# IDE
.psc-ide-port
```

---

## Quick Reference

| Task | Command |
|------|---------|
| Build all | `spago build` |
| Build one package | `spago build -p pkg-name` |
| Bundle frontend | `spago bundle -p frontend-pkg` |
| Run server | `node server/run.js` |
| Run tests | `spago test` |
| Add dependency | Add name to `dependencies:` in package spago.yaml, then `spago build` |
| Check types | `spago build` (or use cclsp `get_diagnostics`) |
| Clean build | `rm -rf output .spago && spago build` |
| Update package set | Change `registry: XX.X.X` in workspace spago.yaml |
