# Marginalia — Project List Snapshot

**Generated**: 2026-04-08
**Total projects**: 149
**By domain**: programming 102, woodworking 16, house 11, infrastructure 10, music 8, garden 2
**By status**: active 102, idea 20, someday 13, defunct 6, done 4, evolved 2, blocked 2

## About the `what-next` skill

This list exists so you can quickly see what's in marginalia without opening the app.
If you print this out and pin it somewhere, use it to remind yourself to run the skill.

Ask any Claude Code session (opened in the project-tracker directory) something like:

> What should I work on?

The `what-next` skill will query the marginalia API across eight heuristic axes
(stale actives, inbox contents, todos in notes, missing descriptions, drifting life
projects, blog candidates, missing thumbnails, running-but-unused services) and
return a short curated list of 3–8 candidates. Each has a slug, a reason it was
suggested, and a concrete action.

The data will be noisy at first. That's intentional: the dismissal loop (telling
Claude "no, that's defunct" / "I already did that") triggers Claude to update the
underlying metadata, so the next invocation is more accurate. Every dismissal
improves the data.

Run it twice a week for a month and the signal-to-noise gets much better.

The skill is particularly useful at the start of a work block when you haven't
decided yet what to focus on — or when you're avoiding a specific project and
want to be challenged with alternatives.

---

## Project tree

Projects shown as a hierarchy. Top-level projects are flush left; children
are indented under their parents. Format:

> **Name** `slug` _status_
> short description (truncated)


- **Bench for downstairs bathroom** `victor-india-whiskey-hotel` _idea_
  Bench for downstairs bathroom From Instructables: https://www.instructables.com/Curved-Garden-Bench-from-Cedar-Laminations/ wit...
- **Claude Inbox** `delta-charlie-echo-tango` _active_
  Special project: dictate freeform thoughts here that mention multiple projects. When ready, ask Claude to process the inbox — C...
- **Coat rack** `charlie-xray-mike-lima` _idea_
  Coat rack ‘
- **codex** `romeo-delta-delta-kilo` _defunct_
- **designervictormanuel** `tango-foxtrot-foxtrot-uniform` _idea_
  Lovely furniture via Core77
- **documentation** `lima-yankee-tango-foxtrot` _active_
- **Fionn’s house notes** `quebec-victor-india-whiskey` _done_
  Reference plans from advising daughter-in-law Fionn on house remodeling. Filed for reference, advice already given.
- **Furniture clippings** `romeo-zulu-delta-echo` _idea_
  Furniture clippings
- **Glazing the Corral** `victor-hotel-yankee-victor` _idea_
  Glaze in the corral — the multi-storey outdoor garden space outside the kitchen with small terrace leading down to the ramparts...
- **hercules** `sierra-alpha-oscar-oscar` _active_
- **House idea** `juliet-echo-xray-hotel` _idea_
  House idea hexagon shelves
- **How about if the front panel of the “greenhouse” became a shade for…** `lima-alpha-whiskey-echo` _evolved_
  Original idea (hinged polycarbonate panels) abandoned. Evolved into a new project: glazing in the entire corral/kitchen terrace...
- **Hylograph** `november-echo-delta-yankee` _active_
  Top-level rollup of the Hylograph ecosystem: libraries, showcases, sites, and infrastructure for declarative interactive data v...
  - **blog.hylograph.net** `victor-quebec-whiskey-quebec` _active_
    The Hylograph blog at blog.hylograph.net. Long-term goal: every project in marginalia eventually becomes a blog post. Ephemeral...
  - **Hylograph Libraries** `alpha-xray-golf-xray` _active_
    The 14+ published PureScript registry packages that make up Hylograph: canvas, D3 kernel, graph, layout, music, optics, selecti...
    - **purescript-hylograph-canvas** `golf-foxtrot-bravo-november` _active_
      Canvas rendering library for Hylograph visualizations.
    - **purescript-hylograph-d3-kernel** `xray-uniform-hotel-bravo` _active_
      D3.js force simulation kernel for Hylograph.
    - **purescript-hylograph-graph** `victor-alpha-juliet-delta` _active_
      Graph algorithms and data structures for PureScript, designed for visualization.
    - **purescript-hylograph-layout** `uniform-november-yankee-uniform` _active_
      Pure PureScript implementations of layout algorithms for hierarchies and flow diagrams.
    - **purescript-hylograph-music** `xray-sierra-quebec-lima` _active_
      Audio interpreter for Hylograph - Data Sonification and Accessibility**
    - **purescript-hylograph-optics** `juliet-lima-sierra-uniform` _active_
      Optics (lenses, prisms, traversals) for Hylograph data structures.
    - **purescript-hylograph-selection** `zulu-juliet-hotel-kilo` _active_
      This is the core package of Hylograph, a PureScript library system for building interactive data visualizations.
    - **purescript-hylograph-simulation** `tango-xray-yankee-quebec` _active_
      Force-directed graph simulation with unified D3 and WASM engine support.
    - **purescript-hylograph-simulation-core** `alpha-lima-hotel-alpha` _active_
      Kernel-agnostic types and interfaces for force simulation.
    - **purescript-hylograph-simulation-halogen** `tango-quebec-echo-quebec` _active_
      Halogen integration for Hylograph force simulations.
    - **purescript-hylograph-transitions** `whiskey-xray-bravo-uniform` _active_
      Animation and transition support for Hylograph visualizations.
    - **purescript-hylograph-wasm-kernel** `india-alpha-india-kilo` _active_
      Rust/WASM force simulation kernel for Hylograph.
    - **purescript-sigil** `echo-mike-delta-golf` _active_
      Typographic rendering for PureScript type signatures.
    - **purescript-sigil-hats** `quebec-golf-oscar-lima` _active_
      Bridge from Sigil layout trees to HATS Tree values for declarative composition in Hylograph visualizations.
  - **Hylograph Showcases** `uniform-alpha-oscar-juliet` _active_
    Demo applications built with Hylograph libraries — Lorenz attractor, neural network viz, Simpson's paradox, prim zoo, tidal rad...
    - **allergy-outlay** `yankee-golf-hotel-oscar` _active_
    - **chimera-bestiary** `papa-zulu-sierra-november` _active_
      Chimera Bestiary: a catalog of hybrid visualizations in HATS
    - **emptier-coinage** `golf-romeo-victor-golf` _active_
      Emptier Coinage: Heterogeneous tree visualization via ShapeTreeDSL
    - **halogen-spider** `romeo-oscar-echo-golf` _active_
      Site Explorer: Interactive route analysis and dead code detection
    - **hylograph-app** `bravo-sierra-charlie-foxtrot` _active_
    - **hylograph-guide** `victor-golf-tango-sierra` _active_
      Hylograph Guide - Interactive HATS examples
    - **hylograph-nn** `zulu-victor-hotel-india` _active_
    - **hypo-punter** `juliet-bravo-juliet-mike` _active_
      PSD3 showcase applications: Embedding Explorer and Grid Explorer.
    - **psd3-arid-keystone** `zulu-mike-november-quebec` _active_
      Annotated Sankey diagram editor using PSD3 TreeAPI
    - **psd3-lorenz-attractor** `whiskey-yankee-juliet-kilo` _active_
      Lorenz attractor visualization showcasing purescript-linear
    - **psd3-tilted-radio** `uniform-romeo-romeo-juliet` _active_
      TidalCycles mini-notation parser for PureScript.
    - **psd3-topics** `sierra-lima-romeo-kilo` _active_
      The Optics Observatory: Interactive exploration of lenses, prisms, and traversals
    - **purescript-eco-saw** `november-echo-papa-india` _active_
    - **purescript-makefile-parser** `whiskey-victor-uniform-november` _active_
    - **scuppered-ligature** `uniform-whiskey-alpha-golf` _active_
      PureScript Edge Lua - The type-safe edge layer for Polyglot PureScript
    - **simpsons-paradox** `victor-tango-november-zulu` _active_
      Simpson's Paradox: Interactive visualization demonstrating statistical paradoxes
    - **The Morphism Zoo** `november-yankee-tango-uniform` _active_
      The Morphism Zoo: Visualizing recursion schemes with a children's book aesthetic
    - **wasm-force-demo** `alpha-papa-tango-victor` _active_
      A proof-of-concept demonstrating WebAssembly-powered force simulation compared to D3.js.
  - **Hylograph Sites & Howto** `delta-echo-yankee-juliet` _active_
    Static sites for the Hylograph ecosystem (deployed via Cloudflare Pages) and the self-contained how-to projects.
    - **hylograph-howto** `romeo-yankee-whiskey-sierra` _active_
      Self-contained how-to projects for the Hylograph library system. Each subdirectory is a standalone project: clone, cd, spago bu...
    - **hylograph-sites** `india-xray-delta-mike` _active_
      Static sites for the Hylograph ecosystem, deployed via Cloudflare Pages.
    - **purescript-hylograph-demos** `victor-romeo-charlie-bravo` _active_
      Small PureScript/Halogen webapps demonstrating individual Hylograph libraries. Assembled from demos that used to be bundled wit...
  - **Polyglot** `lima-yankee-bravo-mike` _active_
    PureScript Polyglot site (purescript-polyglot) — Halogen app that hosts the Hylograph blog, knowledge base, worklogs, and demo ...
    - **Beads PureScript Port** `delta-uniform-yankee-papa` _someday_
      Typed port of distributed git-backed issue tracker
    - **Beads Viz Showcase** `india-juliet-kilo-victor` _someday_
      PSD3 visualization demo for dependency graphs
    - **CE2 Scene Development** `hotel-delta-uniform-sierra` _active_
      Multi-scale visualization views (Galaxy, Solar, Module levels)
    - **CE2 State Machine Refactor** `delta-whiskey-victor-lima` _active_
      Refactoring SceneCoordinator to eliminate inconsistent state
    - **Claude Code PureScript skills** `oscar-uniform-sierra-bravo` _done_
      Effectively finished — turned into Claude Code skills (purescript-ecosystem, purescript-tooling etc.) aimed at AI agents rather...
    - **Code Explorer Evolution** `papa-uniform-echo-quebec` _active_
      Vision for CE as codebase intelligence tool addressing LLM fog of war
    - **D3 Dependency Reduction** `bravo-kilo-sierra-delta` _active_
      Phase 6: remove redundant D3 dependencies from showcases
    - **D3 Migration Audit** `hotel-alpha-echo-mike` _active_
      Comprehensive audit of D3 usage across all showcases
    - **Finally-Tagless AST** `hotel-bravo-uniform-charlie` _active_
      AST design using finally-tagless pattern for extensibility
    - **HATS Projection Typeclass** `lima-whiskey-kilo-mike` _active_
      Type class design for HATS AST projections
    - **Hylograph Deployment** `sierra-zulu-papa-delta` _active_
      Hylograph/polyglot deployment to Cloudflare Pages (static). Need to investigate current disposition — may overlap with polyglot...
    - **Hylograph Guide** `kilo-lima-whiskey-xray` _active_
      Interactive guide merging AST builder + tour structure
    - **Hylograph Tour Structures** `sierra-mike-tango-victor` _active_
      Demo page for Map/Parser/Free visualization
    - **Kernel Separation Phase 2** `kilo-uniform-zulu-echo` _active_
      Continuing separation of canvas kernel from D3 kernel
    - **L-Systems Visualization** `papa-xray-alpha-kilo` _done_
      Tree structure rendering with Hylograph
    - **polyglot-deploy** `tango-hotel-victor-victor` _active_
      Docker deployment of PureScript polyglot showcase examples on the MacMini, served via TailScale Funnel. Showcases include heavy...
    - **Principled AST Design** `november-victor-victor-lima` _active_
      Type-theoretic redesign reducing join constructors to two primitives
    - **Principled AST Design v2** `india-yankee-delta-quebec` _active_
      Iteration on AST design
    - **Release Plan 2026** `kilo-alpha-tango-zulu` _active_
      Master release plan - updated successfully!
    - **Scale.Pure Completion** `quebec-zulu-tango-victor` _active_
      Pure PureScript D3-compatible scale implementation
    - **Sigil SVG Library** `kilo-zulu-sierra-quebec` _active_
      Pure SVG rendering library
    - **Type Explorer** `delta-sierra-xray-foxtrot` _active_
      Browser tool for visualizing type relationships
    - **WASM Canvas Enhancement** `romeo-romeo-tango-romeo` _active_
      Performance improvements for WASM-backed canvas
- **IKEA malm bed** `golf-india-zulu-lima` _defunct_
  Diagram of an IKEA Malm storage bed. No place for it in this house. Not needed.
- **interesting chair** `whiskey-foxtrot-uniform-uniform` _idea_
  interesting chair
- **Jon Thorsen on Twitter** `echo-romeo-quebec-victor` _idea_
  shows a very nice little usage of a wine or oil or grain store in a floor with a glass cover that let's you see inside from abo...
- **keyzen-next** `zulu-whiskey-delta-foxtrot` _active_
- **Laser cut sun screen inspo for conservatory** `uniform-sierra-sierra-sierra` _someday_
  Laser cut sun screen inspo for conservatory There's a photo that goes with this but the real inspiration here is N'awlins balco...
- **Major Apps** `victor-xray-golf-bravo` _active_
  Curated list of substantial standalone applications: Minard (code cartography), ShapedSteer (DAG workbench), CodeExplorer (umbr...
  - **CodeExplorer** `kilo-tango-echo-mike` _active_
    Code cartography umbrella: contains Minard (the main code-cartography app, API + frontend + type explorer + site explorer) plus...
    - **minard** `sierra-tango-golf-bravo` _active_
      Code cartography for PureScript projects.
    - **Minard AI Collaboration** `victor-echo-tango-victor` _done_
      AI-human collaborative code understanding via Minard
    - **Minard Architectural Enforcement** `uniform-foxtrot-alpha-uniform` _active_
      Layer definitions + violation detection. Prerequisite for ShapedSteer
    - **minard-06dee49** `charlie-hotel-victor-alpha` _active_
      Code cartography for PureScript projects.
    - **pausanias** `mike-alpha-alpha-bravo` _active_
  - **Project Tracker** `oscar-romeo-delta-uniform` _active_
    Keyboard-first dispatch board and navigator for all projects. PureScript/Halogen frontend, HTTPurple/DuckDB backend. Accessible...
  - **ShapedSteer** `uniform-alpha-romeo-whiskey` _active_
    Typed DAG workbench — nodes are computations, edges are typed dependencies. Notebook/graph/grid/timeline views, multiple execut...
    - **Async Evaluation Architecture** `charlie-november-uniform-tango` _active_
      Backend service for process management + build execution
    - **Functional Spreadsheet** `uniform-delta-quebec-foxtrot` _someday_
      Spreadsheet as comonad using Store, recursion schemes, lenses
    - **MVP Verticals** `xray-foxtrot-juliet-uniform` _someday_
      Four verticals: Spreadsheet, Notebook, Kanban/Gantt, AI Agent
    - **ShapedSteer Intensive** `zulu-golf-bravo-november` _blocked_
      8-week development sprint for typed DAG workbench. Blocked on Minard release
    - **ShapedSteer Pre-work** `lima-lima-zulu-november` _blocked_
      Meta-planning: multi-agent workflow, dev server architecture, worklogs
    - **Typed Cells Design** `echo-india-quebec-echo` _someday_
      Typed PureScript lambda compilation into cells
    - **Unified DAG Vision** `mike-alpha-november-quebec` _someday_
      Typed DAGs as universal substrate (like Unix byte streams)
    - **Unified Data DSL** `foxtrot-echo-tango-zulu` _someday_
      Finally-tagless DSL with Eval, Deps, Pretty, CodeGen interpreters
- **Measurements for plant stand project** `sierra-delta-november-victor` _idea_
  Measurements for plant stand project Needs solution for curve but surely can be done for less than 160 euro?
- **Music Making** `echo-romeo-hotel-romeo` _active_
  Umbrella for live music performance and composition workflow: MIDI guitar pedalboard (MC6), eurorack modular (ExpertSleepers FH...
  - **ES-config** `uniform-bravo-delta-victor` _active_
    Electron app (package: es9_configurator) for configuring ExpertSleepers FH2/ES-9 eurorack modules via MIDI SysEx. Includes flow...
  - **msm** `zulu-hotel-november-zulu` _active_
    Rust CLI for converting and managing audio samples for eurorack modules (Arbhar, Lubadh, Morphagene, QD, Rample). SQLite sample...
  - **msm-web** `mike-whiskey-papa-tango` _active_
    Web UI for msm — Rust/Axum server + PureScript/Halogen client with waveform player, module-specific sidebars, and a staging are...
  - **NE Alia Firmware** `xray-alpha-charlie-whiskey` _idea_
    Firmware reference documentation and flash scripts for the Noise Engineering Alia platform — base for Basimilus Iteritas Alia, ...
  - **Producing With Your Feet** `alpha-victor-echo-kilo` _active_
    PureScript/Halogen web app (package: explorer-ps) for integrating MIDI guitar pedals with iPad (LoopyPro) and Ableton via iConn...
    - **MC6 SysEx Programming** `romeo-charlie-echo-delta` _evolved_
      MC6 SysEx protocol documentation, reverse-engineered from the Morningstar web app. Not a separate project — belongs as part of ...
  - **tarot-music** `papa-uniform-india-oscar` _active_
    PureScript/Halogen tarot-based music generation — maps tarot cards to musical decisions (key, mode, chords, rhythm) for composi...
- **Nice desk** `november-oscar-india-tango` _idea_
  Nice desk
- **nodepad** `charlie-victor-bravo-echo` _active_
  A design experiment in spatial, AI-augmented thinking. Notes are placed on a spatial canvas; AI classifies them into 14 types a...
- **Personal Infrastructure** `quebec-papa-oscar-charlie` _active_
  Self-hosted infrastructure for digital sovereignty: personal data archive (Infovore), backup, web presence, chat, and RSS/workl...
  - **HeresiarchHalogen** `whiskey-foxtrot-zulu-hotel` _active_
    Possibly the old pre-Claude attempt at andrewcondon.com/heresiarch.com, superseded by the Claude-authored version on Cloudflare...
  - **Infovore Data Sources** `uniform-golf-echo-hotel` _active_
    Master project for consolidating all digital data accumulated over 58 years. 4TB Crucial SSD on MacMini, mirrored locally, back...
    - **Little Snitch rules archive** `tango-alpha-alpha-uniform` _idea_
      Import Little Snitch rules into the infovore-larder-db. Two purposes: (1) preserve them as personal data alongside everything e...
  - **mattermost-tailscale** `oscar-victor-golf-quebec` _active_
    MatterMost running in Docker on the MacMini, served via TailScale. Migrated from private Slack with Paul Harrington. Working an...
  - **nextcloud-mutual-backup** `quebec-echo-lima-zulu` _active_
    Mutual backup plan with Paul Harrington: symmetric discs (4TB Crucial SSD each), send him a disc for his setup in Boston. Also ...
  - **worklog-server** `charlie-oscar-lima-victor` _active_
    Python server that serves worklogs and knowledge base docs from various projects as RSS/Atom feeds, validated with NetNewsWire....
- **Polishing encaustic tiles** `foxtrot-india-lima-golf` _someday_
  Reference link to video on refinishing hydraulic/encaustic tiles. Very labour-intensive process (~4 EUR sandpaper per 20x20cm t...
- **PSD3-Repos** `yankee-echo-foxtrot-charlie` _defunct_
- **PureScript Backends** `india-quebec-oscar-mike` _active_
  Alternative PureScript compiler backends: Erlang (purerl), Lua, Python.
  - **purescript-python-new** `zulu-quebec-bravo-victor` _active_
    A PureScript backend that compiles to Python.
- **PureScript Ports** `charlie-alpha-juliet-echo` _active_
  Ports of libraries from other languages into PureScript. Pure ports: Edward Kmett's machines and linear, Brent Yorgey's diagram...
  - **beads-purs** `oscar-golf-charlie-lima` _active_
    Beads in PureScript — derivative work, heavily refactored and cleaned up by Claude from an upstream source. Beads is the typed ...
  - **purerl-tidal** `quebec-sierra-yankee-echo` _active_
    TidalCycles in PureScript/Erlang (purerl backend) — derivative work, heavily refactored from Alex McLean's original. AST, parse...
  - **PureScript Registry Dashboard** `kilo-zulu-victor-echo` _active_
    Compiler compatibility matrix for the PureScript Registry — written to help Thomas and Fabrizio on the Registry project. Extern...
  - **purescript-diagrams** `mike-november-sierra-november` _active_
    PureScript port of Brent Yorgey's Haskell `diagrams` library — declarative vector graphics with a compositional algebra.
  - **purescript-linear** `juliet-sierra-kilo-echo` _active_
    PureScript port of Edward Kmett's Haskell `linear` library — vectors, matrices, and linear algebra primitives.
  - **purescript-machines** `foxtrot-bravo-victor-kilo` _active_
    PureScript port of Edward Kmett's Haskell `machines` library — typed stream processors with explicit input/output handling.
- **PureScript Tagless D3 2025** `mike-victor-bravo-uniform` _defunct_
  Type-safe D3 visualizations in PureScript - Better fit for functional programming while retaining D3 performance in the browser...
- **purescript-canvas-action** `sierra-alpha-zulu-november` _active_
- **purescript-d3-tagless-II** `mike-november-uniform-papa` _defunct_
  This project demonstrates an embedded DSL for building interactive data visualizations with PureScript, using D3.js both as ins...
- **purescript-html-parser-halogen** `alpha-hotel-echo-zulu` _active_
- **Semi-octagon tiling idea** `quebec-mike-november-tango` _defunct_
  Nice tiling pattern saved for reference. No specific application planned. Not a project.
- **Sisto: A Simple Piece of Furniture with Multiple Configurations - Core77** `romeo-charlie-delta-juliet` _idea_
  Wood working idea / plywood
- **skill-tests** `xray-delta-sierra-bravo` _active_
- **Sofa idea from YouTube** `juliet-sierra-alpha-oscar` _idea_
  Sofa idea from YouTube
- **suentu** `zulu-sierra-sierra-bravo` _active_
- **Table idea from Kristen Dirksen video** `papa-golf-charlie-lima` _idea_
  Table idea from Kristen Dirksen video
- **Things for electrician to do** `xray-golf-golf-bravo` _active_
  Collection of photos documenting small electrical jobs around the house. Plan: get an electrician in for a half-week to batch t...
- **Torii Gate plans** `tango-kilo-zulu-sierra` _someday_
  Reference plans for building a Japanese-style torii gate. Filed for reference — unlikely to be built.
- **TouchOSC** `echo-golf-november-xray` _active_
- **Track lights** `oscar-bravo-yankee-kilo` _someday_
  Collection of working track lights (from Ralph, ex-Burn Perfumery) but no compatible tracks. The track connectors take one pin ...
- **ubiquitous-umbrella** `alpha-november-yankee-mike` _active_
- **Window arch** `mike-victor-victor-papa` _someday_
  Reference image, presumably for a house plan. Low priority, kept for reference.
- **Woodworking** `oscar-hotel-kilo-uniform` _idea_
  Umbrella/rollup for woodworking inspiration and projects. Each child is either an inspiration clipping (joinery study, furnitur...
  - **A-frame tripod joint** `uniform-yankee-quebec-oscar` _idea_
    Joinery study: three pieces meeting in a tripod / A-frame joint. Apple Notes inspiration clipping.
  - **Crossed-leg side table** `juliet-papa-oscar-tango` _idea_
    Furniture design: small side table with X-shaped crossed legs in dark wood, shown from two angles. Apple Notes inspiration clip...
  - **Three-way cross-lap joint** `quebec-november-whiskey-hotel` _idea_
    Joinery study: three cherry wood beams forming an interlocking three-way cross with precise notched/halved joinery. Apple Notes...
  - **Triangular dovetail frame** `whiskey-yankee-echo-tango` _idea_
    Joinery study: walnut triangular frame with dovetail / finger interlocking joinery at the corners, shown from two angles. Apple...
- **Wraparound balcony** `kilo-india-victor-sierra` _someday_
  Image search references for wraparound balconies. Contingency plan for if the neighbouring vacant house is ever purchased — sta...

---

_Generated from http://localhost:3100 — 149 projects total._
