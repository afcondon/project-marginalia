#!/usr/bin/env python3
"""
One-time migration:
  1. Add parent_id column to projects (idempotent)
  2. Create default parent projects for software groups
  3. Assign children based on source_path patterns

Default parents:
  Hylograph                    (top-level rollup)
    Hylograph Libraries        (purescript-hylograph-libs/*)
    Hylograph Showcases        (purescript-hylograph-showcases/*)
    Hylograph Sites & Howto    (hylograph-sites, hylograph-howto)
  PureScript Ports             (purescript-ports/*)
  PureScript Backends          (purescript-backends/*)
  Major Apps                   (Minard, ShapedSteer, CodeExplorer; manually curated)
"""

import duckdb
import random
import sys
from pathlib import Path

DB_PATH = "database/tracker.duckdb"

# Use NATO words to generate slugs in this script
NATO = [
    "alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel",
    "india", "juliet", "kilo", "lima", "mike", "november", "oscar", "papa",
    "quebec", "romeo", "sierra", "tango", "uniform", "victor", "whiskey",
    "xray", "yankee", "zulu",
]


def gen_slug(used: set) -> str:
    while True:
        slug = "-".join(random.choice(NATO) for _ in range(4))
        if slug not in used:
            used.add(slug)
            return slug


def col_exists(conn, table: str, col: str) -> bool:
    rows = conn.execute(f"DESCRIBE {table}").fetchall()
    return any(r[0] == col for r in rows)


def main():
    conn = duckdb.connect(DB_PATH)

    # 1. Add parent_id column if missing
    if not col_exists(conn, "projects", "parent_id"):
        print("Adding parent_id column...")
        conn.execute("ALTER TABLE projects ADD COLUMN parent_id INTEGER")
    else:
        print("parent_id column already exists")

    # Pre-load existing slugs to avoid collisions
    used_slugs = set()
    for (s,) in conn.execute("SELECT slug FROM projects WHERE slug IS NOT NULL").fetchall():
        used_slugs.add(s)

    def create_parent(name: str, description: str, parent_id: int | None = None) -> int:
        existing = conn.execute("SELECT id FROM projects WHERE name = ?", [name]).fetchone()
        if existing:
            print(f"  parent already exists: {name} (#{existing[0]})")
            return existing[0]

        slug = gen_slug(used_slugs)
        conn.execute("""
            INSERT INTO projects (slug, parent_id, name, domain, subdomain, status, description)
            VALUES (?, ?, ?, 'programming', 'rollup', 'active', ?)
        """, [slug, parent_id, name, description])
        new_id = conn.execute("SELECT MAX(id) FROM projects").fetchone()[0]
        conn.execute("""
            INSERT INTO status_history (project_id, old_status, new_status, reason, author)
            VALUES (?, NULL, 'active', 'Created as parent project', 'claude')
        """, [new_id])
        print(f"  + #{new_id} {name} ({slug})")
        return new_id

    def assign_children(parent_id: int, where_clause: str, params: list, label: str):
        # Find candidates not already parented
        rows = conn.execute(f"""
            SELECT id, name FROM projects
            WHERE ({where_clause}) AND parent_id IS NULL AND id != ?
        """, params + [parent_id]).fetchall()
        for cid, cname in rows:
            conn.execute("UPDATE projects SET parent_id = ? WHERE id = ?", [parent_id, cid])
        print(f"    assigned {len(rows)} children ({label})")

    print("\nCreating default parents...\n")

    hylograph = create_parent(
        "Hylograph",
        "Top-level rollup of the Hylograph ecosystem: libraries, showcases, sites, and infrastructure for declarative interactive data visualization in PureScript."
    )

    hylograph_libs = create_parent(
        "Hylograph Libraries",
        "The 14+ published PureScript registry packages that make up Hylograph: canvas, D3 kernel, graph, layout, music, optics, selection, simulation, transitions, WASM kernel, Sigil, HATS.",
        parent_id=hylograph
    )
    assign_children(
        hylograph_libs,
        "source_path LIKE ?",
        ["purescript-hylograph-libs/%"],
        "purescript-hylograph-libs/*"
    )

    hylograph_showcases = create_parent(
        "Hylograph Showcases",
        "Demo applications built with Hylograph libraries — Lorenz attractor, neural network viz, Simpson's paradox, prim zoo, tidal radio, topics, Sankey, and more. Each is a standalone PureScript app.",
        parent_id=hylograph
    )
    assign_children(
        hylograph_showcases,
        "source_path LIKE ?",
        ["purescript-hylograph-showcases/%"],
        "purescript-hylograph-showcases/*"
    )

    hylograph_sites = create_parent(
        "Hylograph Sites & Howto",
        "Static sites for the Hylograph ecosystem (deployed via Cloudflare Pages) and the self-contained how-to projects.",
        parent_id=hylograph
    )
    assign_children(
        hylograph_sites,
        "source_path LIKE ? OR source_path LIKE ?",
        ["hylograph-sites%", "hylograph-howto%"],
        "hylograph-sites, hylograph-howto"
    )

    ports = create_parent(
        "PureScript Ports",
        "Ports of libraries from other languages into PureScript. Pure ports: Edward Kmett's machines and linear, Brent Yorgey's diagrams. Derivative works: beads-purs, purerl-tidal."
    )
    assign_children(
        ports,
        "source_path LIKE ?",
        ["purescript-ports/%"],
        "purescript-ports/*"
    )

    backends = create_parent(
        "PureScript Backends",
        "Alternative PureScript compiler backends: Erlang (purerl), Lua, Python."
    )
    assign_children(
        backends,
        "source_path LIKE ?",
        ["purescript-backends/%"],
        "purescript-backends/*"
    )

    # Major apps — manually curated by name match
    major_apps = create_parent(
        "Major Apps",
        "Curated list of substantial standalone applications: Minard (code cartography), ShapedSteer (DAG workbench), CodeExplorer (umbrella for Minard and Type Explorer), and Project Tracker (this app, dogfooding)."
    )
    # Match by name patterns
    major_app_names = ["minard", "ShapedSteer", "CodeExplorer", "Project Tracker"]
    for n in major_app_names:
        rows = conn.execute(
            "SELECT id, name FROM projects WHERE LOWER(name) = LOWER(?) AND parent_id IS NULL",
            [n]
        ).fetchall()
        for cid, cname in rows:
            conn.execute("UPDATE projects SET parent_id = ? WHERE id = ?", [major_apps, cid])
            print(f"    assigned: {cname}")

    # Summary
    print("\n=== Summary ===")
    rows = conn.execute("""
        SELECT p.id, p.name, COUNT(c.id) AS n_children
        FROM projects p
        LEFT JOIN projects c ON c.parent_id = p.id
        WHERE p.subdomain = 'rollup'
        GROUP BY p.id, p.name
        ORDER BY p.id
    """).fetchall()
    for pid, name, n in rows:
        print(f"  #{pid} {name}: {n} children")

    conn.close()


if __name__ == "__main__":
    main()
