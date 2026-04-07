#!/usr/bin/env python3
"""Second pass: create ShapedSteer, CodeExplorer, Polyglot parents and adopt their plans."""

import duckdb
import random

DB_PATH = "database/tracker.duckdb"

NATO = [
    "alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel",
    "india", "juliet", "kilo", "lima", "mike", "november", "oscar", "papa",
    "quebec", "romeo", "sierra", "tango", "uniform", "victor", "whiskey",
    "xray", "yankee", "zulu",
]


def gen_slug(used):
    while True:
        slug = "-".join(random.choice(NATO) for _ in range(4))
        if slug not in used:
            used.add(slug)
            return slug


def main():
    conn = duckdb.connect(DB_PATH)

    used = set()
    for (s,) in conn.execute("SELECT slug FROM projects WHERE slug IS NOT NULL").fetchall():
        used.add(s)

    major_apps = conn.execute("SELECT id FROM projects WHERE name = 'Major Apps'").fetchone()[0]

    def create_parent(name, description, parent_id=None):
        existing = conn.execute("SELECT id FROM projects WHERE name = ?", [name]).fetchone()
        if existing:
            print(f"  exists: {name} (#{existing[0]})")
            return existing[0]
        slug = gen_slug(used)
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

    def adopt(parent_id, ids, label=""):
        n = 0
        for cid in ids:
            r = conn.execute("UPDATE projects SET parent_id = ? WHERE id = ? AND parent_id IS NULL", [parent_id, cid])
            n += 1
        print(f"    adopted {n} {label}")

    shapedsteer = create_parent(
        "ShapedSteer",
        "Typed DAG workbench — nodes are computations, edges are typed dependencies. Notebook/graph/grid/timeline views, multiple executors (human, AI). Has its own ARCHITECTURE.md with strict layer rules.",
        parent_id=major_apps
    )
    ss_ids = [r[0] for r in conn.execute("""
        SELECT id FROM projects
        WHERE (source_path LIKE 'ShapedSteer/%' OR LOWER(name) LIKE 'shapedsteer%')
          AND parent_id IS NULL
          AND id != ?
    """, [shapedsteer]).fetchall()]
    adopt(shapedsteer, ss_ids, "ShapedSteer plans")

    codeexplorer = create_parent(
        "CodeExplorer",
        "Code cartography umbrella: contains Minard (the main code-cartography app, API + frontend + type explorer + site explorer) plus a Type Explorer side project. DuckDB backend.",
        parent_id=major_apps
    )
    ce_ids = [r[0] for r in conn.execute("""
        SELECT id FROM projects
        WHERE (source_path LIKE 'CodeExplorer/%' OR LOWER(name) LIKE 'minard%')
          AND parent_id IS NULL
    """).fetchall()]
    # Also reparent the existing minard (#35) which got assigned to Major Apps directly
    minard_row = conn.execute("SELECT id FROM projects WHERE name = 'minard'").fetchone()
    if minard_row:
        conn.execute("UPDATE projects SET parent_id = ? WHERE id = ?", [codeexplorer, minard_row[0]])
    adopt(codeexplorer, ce_ids, "CodeExplorer/Minard")

    hylograph_id = conn.execute("SELECT id FROM projects WHERE name = 'Hylograph'").fetchone()[0]
    polyglot = create_parent(
        "Polyglot",
        "PureScript Polyglot site (purescript-polyglot) — Halogen app that hosts the Hylograph blog, knowledge base, worklogs, and demo showcases of multiple PureScript backends.",
        parent_id=hylograph_id
    )
    pg_ids = [r[0] for r in conn.execute("""
        SELECT id FROM projects
        WHERE (LOWER(name) LIKE '%polyglot%' OR repo = 'purescript-polyglot')
          AND parent_id IS NULL
    """).fetchall()]
    adopt(polyglot, pg_ids, "polyglot-related")

    print("\n=== Parent summary ===")
    rows = conn.execute("""
        SELECT p.id, p.name, COUNT(c.id) AS n
        FROM projects p
        LEFT JOIN projects c ON c.parent_id = p.id
        WHERE p.subdomain = 'rollup'
        GROUP BY p.id, p.name
        ORDER BY p.id
    """).fetchall()
    for pid, name, n in rows:
        print(f"  #{pid:3d} {name}: {n} children")

    print("\n=== Remaining programming orphans (no parent, no children) ===")
    rows = conn.execute("""
        SELECT p.id, p.slug, p.name
        FROM projects p
        LEFT JOIN projects c ON c.parent_id = p.id
        WHERE p.domain = 'programming' AND p.parent_id IS NULL AND p.subdomain != 'rollup'
        GROUP BY p.id, p.slug, p.name
        HAVING COUNT(c.id) = 0
        ORDER BY p.id
    """).fetchall()
    for r in rows:
        print(f"  {r[0]:3d}  {(r[1] or '-')[:40]:40s}  {r[2]}")

    conn.close()


if __name__ == "__main__":
    main()
