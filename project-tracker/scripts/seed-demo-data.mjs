// Seed script — populate a fresh Marginalia database with fictional demo
// projects for screen-recording, iPhone capture-client testing, and first-
// run demos. Does NOT touch any real data: it hits the API like any other
// client, so it only affects whatever DB the running server is pointing at.
//
// USAGE:
//
//   # Against the running local server (default)
//   node scripts/seed-demo-data.mjs
//
//   # Against a different host (e.g. MacMini over Tailscale)
//   MARGINALIA_API=https://macmini.tailnet.ts.net node scripts/seed-demo-data.mjs
//
// SAFETY: refuses to run if the target already has >= 3 projects, so you
// can't accidentally pollute a live database. Pass --force to bypass.
//
// The fictional persona: a maker who works across programming, music,
// house, woodworking, garden, and infrastructure. Enough cross-domain
// content that the Register's tiered grid has visual variety out of the
// box, enough prose that the blog classification feature has something
// to point at, and some parent/child structure for the ancestor filter.

const API = process.env.MARGINALIA_API || 'http://localhost:3100';
const FORCE = process.argv.includes('--force');

// ---------------------------------------------------------------------------
// HTTP helpers
// ---------------------------------------------------------------------------

async function req(method, path, body) {
  const opts = { method, headers: { 'Content-Type': 'application/json' } };
  if (body !== undefined) opts.body = JSON.stringify(body);
  const resp = await fetch(`${API}${path}`, opts);
  if (!resp.ok) {
    const text = await resp.text();
    throw new Error(`${method} ${path} → ${resp.status}: ${text}`);
  }
  return resp.json();
}

const POST = (path, body) => req('POST', path, body);
const PUT = (path, body) => req('PUT', path, body);
const GET = (path) => req('GET', path);

// ---------------------------------------------------------------------------
// Demo data
// ---------------------------------------------------------------------------

// Top-level projects. Each may have `children` that become child projects
// with parentId set to the top-level's newly-minted id. Fields not set
// default to sensible values on the server (status=idea, etc).
const PROJECTS = [
  // -------------------- PROGRAMMING --------------------
  {
    name: 'Scupper',
    domain: 'programming',
    subdomain: 'tools',
    status: 'active',
    description:
      'A tiny CLI that watches a directory for new audio files, slices them at silence, tags with BPM, and drops the chunks into the right eurorack sample folder. Written in Rust because the watcher tree was eating frame budgets in Python.',
    tags: ['cli', 'rust', 'audio', 'eurorack'],
    blogStatus: 'wanted',
  },
  {
    name: 'weatherplot',
    domain: 'programming',
    subdomain: 'web',
    status: 'active',
    description:
      'Small PureScript/Halogen webapp that plots hourly forecast data from a local weather station against the multi-year hourly average. Pulls observations from a sqlite backend. Built to answer "is this weird or is this normal" questions without opening a proper data-science stack.',
    tags: ['halogen', 'purescript', 'dataviz', 'weather'],
    blogStatus: 'drafted',
    blogContent:
      '# Plotting the weird against the normal\n\nIf you live somewhere with changeable weather, the interesting question on any given day is rarely "what will the temperature be" — your phone already tells you that. The interesting question is "is this temperature unusual."\n\nweatherplot answers that question by overlaying the forecast you just received against the multi-year hourly average for this exact date. Anomalies leap out of the chart the moment you look at it.\n\n## The data\n\nThe station outside logs every five minutes. I downsample to hourly…',
  },
  {
    name: 'zine-dsl',
    domain: 'programming',
    subdomain: 'layout',
    status: 'idea',
    description:
      'A small declarative layout language for print zines — specify a page grid, paste in markdown sections, get a pair of PDFs (screen reading + imposed for duplex printing). Output targets A5 folded-to-A6. Meant to replace the fight with InDesign for quarterly personal zines.',
    tags: ['dsl', 'print', 'typography', 'layout'],
    blogStatus: 'wanted',
  },
  {
    name: 'kbd-firmware-ergo42',
    domain: 'programming',
    subdomain: 'firmware',
    status: 'done',
    description:
      'QMK firmware for a hand-wired Ergo42. Six layers: base, symbols, nav, media, numpad, and a "coding" layer with brackets on home row. Includes a small Python harness that round-trips the keymap through a JSON representation for easy diffing.',
    tags: ['firmware', 'qmk', 'keyboards'],
    blogStatus: 'published',
    blogContent:
      '# A keymap you can diff\n\nQMK keymaps live in a C header file with nested macro invocations. That makes them readable to humans but hellish to diff across commits: move one key and the whole block realigns.\n\nI wrote a tiny Python harness that converts between the C keymap and a JSON representation. When I change a key, I edit the JSON, regenerate the C, and the diff is exactly the line I changed…',
  },
  {
    name: 'raytracer-weekend',
    domain: 'programming',
    subdomain: 'graphics',
    status: 'defunct',
    description:
      'A weekend walkthrough of Peter Shirley\'s "Ray Tracing in One Weekend" in Haskell. Finished chapter 9 (dielectrics) before abandoning because the floating-point arithmetic was more instructive than the rendering.',
    tags: ['haskell', 'graphics', 'learning'],
  },

  // -------------------- MUSIC --------------------
  {
    name: 'Autumn EP',
    domain: 'music',
    subdomain: 'release',
    status: 'active',
    description:
      'A six-track EP recorded mostly on the modular + guitar loop pedal. Working title for each track is a tree species. Aim is 22 minutes total — deliberately LP-side length for potential vinyl pressing next year.',
    tags: ['album', 'eurorack', 'ambient', 'ship-2026'],
    blogStatus: 'drafted',
    children: [
      {
        name: 'Hornbeam',
        domain: 'music',
        subdomain: 'track',
        status: 'active',
        description:
          'Opening track. Slow-attack pad from the Beads + a single long sustained E on the Take 5, delayed against itself at a non-integer ratio so it precesses.',
        tags: ['track', 'ambient'],
      },
      {
        name: 'Walnut',
        domain: 'music',
        subdomain: 'track',
        status: 'active',
        description:
          'Second track. Hand-played piano sample chopped and re-triggered by Pam\'s at a swung 7/8. The most "melodic" track on the EP.',
        tags: ['track', 'piano', 'rhythm'],
      },
      {
        name: 'Rowan',
        domain: 'music',
        subdomain: 'track',
        status: 'idea',
        description:
          'Third track. Still sketch-only. Thinking vocoded field recording (rain on the porch roof) as the rhythm bed.',
        tags: ['track', 'field-recording'],
      },
    ],
  },
  {
    name: 'MIDI controller patchbook',
    domain: 'music',
    subdomain: 'performance',
    status: 'active',
    description:
      'Working patch library for the Morningstar MC6 and Midifighter Twister. Each song in the live set has a dedicated page with labeled CC sends for the loop pedal, the modular interface, and Ableton\'s return tracks. Committed as JSON so I can regenerate from templates.',
    tags: ['midi', 'live', 'mc6', 'twister'],
    blogStatus: 'wanted',
  },
  {
    name: 'Tarot compositional prompts',
    domain: 'music',
    subdomain: 'composition',
    status: 'someday',
    description:
      'A tarot-style deck where each card is a compositional prompt: "start with a loop you wouldn\'t loop", "lose a beat every four bars", "tune everything to a field recording". Built as a physical deck for pulls before a session.',
    tags: ['tarot', 'composition', 'physical'],
  },

  // -------------------- HOUSE --------------------
  {
    name: 'Kitchen re-tile',
    domain: 'house',
    subdomain: 'renovation',
    status: 'active',
    description:
      'Replacing the 1990s ceramic splashback with handmade zellige in a muted green. Already sourced from a supplier in Fez; the tiles arrive in six weeks. Plan: rip existing, skim, install, grout, seal. Budget three weekends and a sick-of-it ratio of 1:2.',
    tags: ['kitchen', 'tile', 'renovation'],
  },
  {
    name: 'Hallway repaint',
    domain: 'house',
    subdomain: 'decor',
    status: 'done',
    description:
      'Farrow & Ball Railings on the spindles and Strong White on the walls and risers. Took eight days with two coats on everything. Marine-varnished the handrail.',
    tags: ['paint', 'hallway'],
  },
  {
    name: 'Window upgrade survey',
    domain: 'house',
    subdomain: 'envelope',
    status: 'someday',
    description:
      'Audit of all twelve sash windows for draft-proofing + secondary glazing. Need to decide which windows get full restoration vs which get secondary panels vs which just need brush-pile replacement.',
    tags: ['windows', 'energy', 'audit'],
  },
  {
    name: 'Porch railing repair',
    domain: 'house',
    subdomain: 'exterior',
    status: 'blocked',
    description:
      'The southwest-facing section of the porch railing has rotted at the newel post. Blocked on sourcing matching oak mouldings — tried two local yards and neither had the profile.',
    tags: ['porch', 'carpentry', 'repair'],
  },

  // -------------------- WOODWORKING --------------------
  {
    name: 'Walnut bookshelf',
    domain: 'woodworking',
    subdomain: 'furniture',
    status: 'active',
    description:
      'Hand-cut dovetailed walnut bookshelf, 5 feet tall, asymmetric shelf spacing following a rough Fibonacci division. Shelves are through-tenoned with wedged tenons. First large case piece. Oil finish only.',
    tags: ['furniture', 'walnut', 'dovetail', 'hand-tool'],
    blogStatus: 'wanted',
  },
  {
    name: 'Live-edge dining table',
    domain: 'woodworking',
    subdomain: 'furniture',
    status: 'someday',
    description:
      'A live-edge slab for the dining room. Have a 2.4m english elm slab drying in the shed since last winter. Need to decide on base — thinking a steel trestle rather than another wooden base.',
    tags: ['furniture', 'elm', 'slab', 'dining'],
  },
  {
    name: 'Kitchen utensil rack',
    domain: 'woodworking',
    subdomain: 'small-project',
    status: 'done',
    description:
      'A small oak magnetic-strip rack for the kitchen wall. Weekend project. Housing a row of Japanese knives and a couple of offset spatulas. Finished with raw linseed oil, monthly re-oil.',
    tags: ['oak', 'kitchen', 'small'],
  },
  {
    name: 'Kid\'s toolbox',
    domain: 'woodworking',
    subdomain: 'small-project',
    status: 'idea',
    description:
      'Traditional pine toolbox, dovetailed, about 18 inches. For the kid\'s birthday. Thinking of pre-drilling for a few starter tools and painting the inside a bright colour.',
    tags: ['pine', 'gift', 'small'],
  },

  // -------------------- GARDEN --------------------
  {
    name: 'Raised bed build',
    domain: 'garden',
    subdomain: 'structure',
    status: 'active',
    description:
      'Three 2m × 1m raised beds at the south side of the garden. Larch boards (no pressure treatment), keyed corners, landscape fabric lining. Fill with a lasagna-method mix: cardboard, manure, leaf mould, topsoil.',
    tags: ['beds', 'larch', 'vegetables'],
  },
  {
    name: 'Pond build',
    domain: 'garden',
    subdomain: 'water',
    status: 'someday',
    description:
      'A small wildlife pond at the low point of the garden where water already pools in winter. Flexible liner over sand. Native planting. Deliberately no fish — it\'s a habitat, not a feature.',
    tags: ['pond', 'wildlife', 'water'],
  },
  {
    name: 'Drip irrigation loop',
    domain: 'garden',
    subdomain: 'infrastructure',
    status: 'blocked',
    description:
      'A drip irrigation manifold with pressure-reducing valves for the raised beds. Blocked on the raised bed build — no point laying irrigation before the beds are in.',
    tags: ['irrigation', 'infrastructure'],
  },
  {
    name: 'Compost rotation system',
    domain: 'garden',
    subdomain: 'soil',
    status: 'done',
    description:
      'A three-bin open compost setup made from reclaimed pallets. Hot bin, maturing bin, finished bin. Has turned out roughly 400L of usable compost over the last year.',
    tags: ['compost', 'pallets', 'soil'],
  },

  // -------------------- INFRASTRUCTURE --------------------
  {
    name: 'Home NAS',
    domain: 'infrastructure',
    subdomain: 'storage',
    status: 'active',
    description:
      'Self-built NAS on old ThinkCentre hardware running TrueNAS Scale, two mirrored 8TB drives plus a small SSD for the boot + metadata pool. Serves Time Machine, SMB shares, and the photo archive.',
    tags: ['nas', 'truenas', 'self-hosted'],
    blogStatus: 'wanted',
  },
  {
    name: 'Off-site backup',
    domain: 'infrastructure',
    subdomain: 'backup',
    status: 'idea',
    description:
      'A mirror-site backup strategy: a second TrueNAS box living at a friend\'s house, joined to the same Tailscale tailnet, rsync\'d nightly. Mutual arrangement so we back each other up.',
    tags: ['backup', 'tailscale', 'mutual'],
  },
  {
    name: 'Router config as code',
    domain: 'infrastructure',
    subdomain: 'network',
    status: 'done',
    description:
      'OpenWRT config committed to a private git repo with per-environment overlays. VLAN for guest wifi, VLAN for IoT, VLAN for trusted. Router firmware updates are now a `git pull && reload-wan` instead of a web-UI scavenger hunt.',
    tags: ['openwrt', 'network', 'infrastructure'],
  },
  {
    name: 'Photo archive dedup',
    domain: 'infrastructure',
    subdomain: 'archive',
    status: 'blocked',
    description:
      'The photo archive has ~30k duplicates from multiple migrations over the years. Need a tool that matches perceptual hashes, not filename or exact bytes. Blocked on deciding whether to write something myself or use Czkawka.',
    tags: ['photos', 'dedup', 'archive'],
  },
];

// ---------------------------------------------------------------------------
// Seed execution
// ---------------------------------------------------------------------------

async function main() {
  console.log(`seed target: ${API}`);

  // Safety check
  const existing = await GET('/api/projects');
  if (existing.count >= 3 && !FORCE) {
    console.error(
      `refusing to seed: target already has ${existing.count} projects. ` +
      `pass --force to override.`
    );
    process.exit(1);
  }

  let created = 0;
  let failed = 0;

  for (const proj of PROJECTS) {
    const { children, tags, blogStatus, blogContent, ...body } = proj;
    try {
      const resp = await POST('/api/projects', body);
      const parent = resp.projects[0];
      console.log(`  + ${parent.id.toString().padStart(3)} ${parent.name}`);
      created++;

      // Tags via the tag endpoint
      if (tags && tags.length) {
        for (const t of tags) {
          await POST(`/api/projects/${parent.id}/tags`, { tag: t });
        }
      }

      // Blog status + content via PUT
      if (blogStatus || blogContent) {
        const update = {};
        if (blogStatus) update.blogStatus = blogStatus;
        if (blogContent) update.blogContent = blogContent;
        await PUT(`/api/projects/${parent.id}`, update);
      }

      // Children, if any
      if (children && children.length) {
        for (const child of children) {
          const { tags: cTags, blogStatus: cBs, blogContent: cBc, ...cBody } = child;
          const cResp = await POST('/api/projects', {
            ...cBody,
            parentId: parent.id,
          });
          const childProj = cResp.projects[0];
          console.log(`    + ${childProj.id.toString().padStart(3)} ${childProj.name}`);
          created++;
          if (cTags && cTags.length) {
            for (const t of cTags) {
              await POST(`/api/projects/${childProj.id}/tags`, { tag: t });
            }
          }
          if (cBs || cBc) {
            const cUpdate = {};
            if (cBs) cUpdate.blogStatus = cBs;
            if (cBc) cUpdate.blogContent = cBc;
            await PUT(`/api/projects/${childProj.id}`, cUpdate);
          }
        }
      }
    } catch (err) {
      console.error(`  ! ${proj.name}: ${err.message}`);
      failed++;
    }
  }

  console.log();
  console.log(`done. created ${created}, failed ${failed}`);
}

main().catch((err) => {
  console.error('fatal:', err.message);
  process.exit(1);
});
