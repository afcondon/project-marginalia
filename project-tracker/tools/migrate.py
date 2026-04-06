#!/usr/bin/env python3
"""
Seed data migration: infovore-larder-db -> project-tracker DuckDB

Reads from:
  - infovore-larder-db/data/projects/catalog.db  (34 plans)
  - infovore-larder-db/data/projects/repos.db    (101 repos, 65 owned)
  - infovore-larder-db/data/notes/consolidated/house-projects.md

Writes to:
  - database/tracker.duckdb

Status mapping:
  active   -> active
  someday  -> someday
  done     -> done
  blocked  -> blocked
  archived -> defunct
"""

import re
import sqlite3
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# Resolve paths relative to this script
# ---------------------------------------------------------------------------

SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = SCRIPT_DIR.parent
INFOVORE_ROOT = PROJECT_ROOT.parent.parent / "infovore-larder-db"

CATALOG_DB = INFOVORE_ROOT / "data" / "projects" / "catalog.db"
REPOS_DB = INFOVORE_ROOT / "data" / "projects" / "repos.db"
HOUSE_PROJECTS_MD = INFOVORE_ROOT / "data" / "notes" / "consolidated" / "house-projects.md"
SCHEMA_SQL = PROJECT_ROOT / "database" / "schema.sql"
TRACKER_DB = PROJECT_ROOT / "database" / "tracker.duckdb"

# ---------------------------------------------------------------------------
# Status mapping from old catalog to new schema
# ---------------------------------------------------------------------------

STATUS_MAP = {
    "active": "active",
    "someday": "someday",
    "done": "done",
    "blocked": "blocked",
    "archived": "defunct",
}

# ---------------------------------------------------------------------------
# Domain classification for repos that aren't already plans
# ---------------------------------------------------------------------------

# Repos that are already represented by plans (by repo name) -- skip as projects
# but the plan import will cover them
PLAN_REPOS = set()  # populated dynamically from plans data

# Domain/subdomain inference from repo path
REPO_DOMAIN_MAP = {
    "purescript-hylograph-libs": ("programming", "hylograph"),
    "purescript-hylograph-showcases": ("programming", "hylograph"),
    "purescript-polyglot": ("programming", "hylograph"),
    "hylograph-sites": ("programming", "hylograph"),
    "hylograph-howto": ("programming", "hylograph"),
    "CodeExplorer": ("programming", "minard"),
    "ShapedSteer": ("programming", "shapedsteer"),
    "music": ("music", None),
    "purescript-backends": ("programming", "ecosystem"),
    "purescript-ports": ("programming", "ecosystem"),
    "HeresiarchHalogen": ("infrastructure", "self-hosting"),
    "infovore-larder-db": ("infrastructure", "archive"),
    "mattermost-tailscale": ("infrastructure", "self-hosting"),
    "nextcloud-mutual-backup": ("infrastructure", "backup"),
    "polyglot-deploy": ("infrastructure", "deployment"),
    "worklog-server": ("infrastructure", "self-hosting"),
    "skill-tests": ("programming", "ecosystem"),
    "archived": ("programming", None),
    "GitHub": ("programming", None),
    "flaming-octo-happiness": ("programming", None),
    "registry-index": ("programming", "ecosystem"),
}


def infer_repo_domain(path):
    """Infer domain/subdomain from repo path."""
    parts = path.split("/")
    top = parts[0] if parts else ""

    if top in REPO_DOMAIN_MAP:
        return REPO_DOMAIN_MAP[top]

    # Hylograph library repos
    if "hylograph" in top.lower():
        return ("programming", "hylograph")

    # PureScript ecosystem
    if top.startswith("purescript-"):
        return ("programming", "ecosystem")

    return ("programming", None)


# ---------------------------------------------------------------------------
# House projects parser
# ---------------------------------------------------------------------------

def parse_house_projects(md_path):
    """Parse house-projects.md into project entries.

    Each note starts with '## <title>' followed by '*<date>*' and content.
    We classify into house/woodworking/garden based on keywords.
    """
    if not md_path.exists():
        print(f"  Warning: {md_path} not found, skipping house projects")
        return []

    text = md_path.read_text(encoding="utf-8")
    entries = []

    # Split on '---' separators, then parse each section
    sections = re.split(r"\n---\n", text)

    for section in sections:
        section = section.strip()
        if not section:
            continue

        # Extract title from ## heading
        title_match = re.match(r"^##\s+(.+)$", section, re.MULTILINE)
        if not title_match:
            continue

        title = title_match.group(1).strip()

        # Skip generic "New Note" entries
        if title == "New Note":
            continue

        # Extract date
        date_match = re.search(r"\*(\d{4}-\d{2}-\d{2})\*", section)
        date_str = date_match.group(1) if date_match else None

        # Extract body (everything after title and date lines)
        body_lines = []
        past_header = False
        for line in section.split("\n"):
            if past_header:
                # Skip image placeholders
                if line.strip() and line.strip() != "\ufffc":
                    body_lines.append(line)
            elif line.startswith("*") and line.endswith("*"):
                past_header = True
            elif line.startswith("##"):
                continue
            else:
                past_header = True
                if line.strip() and line.strip() != "\ufffc":
                    body_lines.append(line)

        description = "\n".join(body_lines).strip()
        # Clean up any remaining object replacement characters
        description = description.replace("\ufffc", "").strip()

        # Classify domain and subdomain based on keywords
        combined = (title + " " + description).lower()
        domain, subdomain = classify_house_project(combined)

        entries.append({
            "name": title,
            "domain": domain,
            "subdomain": subdomain,
            "status": "idea",  # house project notes are aspirational
            "description": description if description else None,
            "source_path": "infovore-larder-db/data/notes/consolidated/house-projects.md",
            "created_at": date_str,
        })

    return entries


def classify_house_project(text):
    """Classify a house project note into domain/subdomain."""
    woodworking_keywords = [
        "bench", "desk", "shelf", "shelves", "shelving", "table",
        "chair", "furniture", "woodwork", "plywood", "cedar", "wood",
        "coat rack", "sofa", "plant stand", "hexagon shelves",
    ]
    garden_keywords = [
        "garden", "torii", "gate", "greenhouse", "shade", "sunken",
        "planting", "landscap", "outdoor",
    ]
    electrical_keywords = ["electrician", "track light", "light"]
    tiling_keywords = ["tiling", "tile", "encaustic", "octagon"]
    renovation_keywords = [
        "window", "arch", "balcony", "wraparound", "bed", "ikea",
        "malm", "laser cut", "sun screen", "conservatory",
        "fionn", "house",
    ]

    for kw in woodworking_keywords:
        if kw in text:
            return ("woodworking", "furniture")

    for kw in garden_keywords:
        if kw in text:
            return ("garden", "structures")

    for kw in electrical_keywords:
        if kw in text:
            return ("house", "electrical")

    for kw in tiling_keywords:
        if kw in text:
            return ("house", "tiling")

    for kw in renovation_keywords:
        if kw in text:
            return ("house", "renovation")

    # Default: house
    return ("house", None)


# ---------------------------------------------------------------------------
# Main migration logic
# ---------------------------------------------------------------------------

def check_dependencies():
    """Verify required packages are available."""
    try:
        import duckdb  # noqa: F401
    except ImportError:
        print("Error: duckdb Python package not installed.")
        print("Install with: pip3 install duckdb")
        sys.exit(1)


def create_schema(duck_conn):
    """Apply the DuckDB schema from schema.sql."""
    schema_sql = SCHEMA_SQL.read_text(encoding="utf-8")
    duck_conn.execute(schema_sql)
    print(f"  Applied schema from {SCHEMA_SQL}")


def migrate_plans(duck_conn):
    """Import plans from catalog.db into projects table."""
    if not CATALOG_DB.exists():
        print(f"  Warning: {CATALOG_DB} not found, skipping plans")
        return 0

    sqlite_conn = sqlite3.connect(str(CATALOG_DB))
    sqlite_conn.row_factory = sqlite3.Row
    cursor = sqlite_conn.cursor()
    cursor.execute("SELECT * FROM plans ORDER BY id")
    plans = cursor.fetchall()

    count = 0
    for plan in plans:
        status = STATUS_MAP.get(plan["status"], plan["status"])
        PLAN_REPOS.add(plan["repo"])

        duck_conn.execute(
            """
            INSERT INTO projects (name, domain, subdomain, status, description,
                                  source_path, repo, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                plan["name"],
                plan["domain"],
                plan["subdomain"],
                status,
                plan["summary"],
                plan["source_path"],
                plan["repo"],
                plan["created_at"],
                plan["updated_at"],
            ],
        )

        # Get auto-assigned id of the row we just inserted
        last_id = duck_conn.execute(
            "SELECT MAX(id) FROM projects"
        ).fetchone()[0]

        duck_conn.execute(
            """
            INSERT INTO status_history (project_id, old_status, new_status, reason)
            VALUES (?, NULL, ?, 'Imported from infovore-larder-db catalog')
            """,
            [last_id, status],
        )
        count += 1

    sqlite_conn.close()
    return count


def migrate_repos(duck_conn):
    """Import owned repos from repos.db as projects.

    Only imports repos that are owned (is_mine=1) and not already
    represented by a plan entry. Creates them as programming projects
    with appropriate domain/subdomain inference.
    """
    if not REPOS_DB.exists():
        print(f"  Warning: {REPOS_DB} not found, skipping repos")
        return 0

    sqlite_conn = sqlite3.connect(str(REPOS_DB))
    sqlite_conn.row_factory = sqlite3.Row
    cursor = sqlite_conn.cursor()
    cursor.execute("SELECT * FROM repos WHERE is_mine = 1 ORDER BY id")
    repos = cursor.fetchall()

    # Collect repo names already present as plans (by repo field)
    existing = duck_conn.execute(
        "SELECT DISTINCT repo FROM projects WHERE repo IS NOT NULL"
    ).fetchall()
    existing_repos = {row[0] for row in existing}

    count = 0
    for repo in repos:
        repo_name = repo["name"]
        repo_path = repo["path"]

        # Skip repos already represented by plan entries
        # Match on name or on first component of path
        top_dir = repo_path.split("/")[0]
        if repo_name in existing_repos or top_dir in existing_repos:
            continue

        # Skip archived repos -- mark as defunct instead
        is_archived = repo_path.startswith("archived/")

        domain, subdomain = infer_repo_domain(repo_path)
        status = "defunct" if is_archived else "active"
        description = repo["description"] if repo["description"] else None

        duck_conn.execute(
            """
            INSERT INTO projects (name, domain, subdomain, status, description,
                                  source_path, repo, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                repo_name,
                domain,
                subdomain,
                status,
                description,
                repo_path,
                repo_name,
                repo["created_at"],
                repo["created_at"],
            ],
        )

        last_id = duck_conn.execute(
            "SELECT MAX(id) FROM projects"
        ).fetchone()[0]

        duck_conn.execute(
            """
            INSERT INTO status_history (project_id, old_status, new_status, reason)
            VALUES (?, NULL, ?, 'Imported from infovore-larder-db repos')
            """,
            [last_id, status],
        )
        count += 1

    sqlite_conn.close()
    return count


def migrate_house_projects(duck_conn):
    """Import house/woodworking/garden projects from house-projects.md."""
    entries = parse_house_projects(HOUSE_PROJECTS_MD)

    count = 0
    for entry in entries:
        duck_conn.execute(
            """
            INSERT INTO projects (name, domain, subdomain, status, description,
                                  source_path, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                entry["name"],
                entry["domain"],
                entry["subdomain"],
                entry["status"],
                entry["description"],
                entry["source_path"],
                entry["created_at"],
                entry["created_at"],
            ],
        )

        last_id = duck_conn.execute(
            "SELECT MAX(id) FROM projects"
        ).fetchone()[0]

        duck_conn.execute(
            """
            INSERT INTO status_history (project_id, old_status, new_status, reason)
            VALUES (?, NULL, ?, 'Imported from house-projects.md')
            """,
            [last_id, entry["status"]],
        )
        count += 1

    return count


def create_seed_tags(duck_conn):
    """Create initial tags and tag assignments based on imported data."""
    # Create useful cross-cutting tags
    seed_tags = [
        "hylograph",
        "minard",
        "shapedsteer",
        "ship-2026",
        "claude-authored",
        "purescript",
        "infrastructure",
        "music",
        "house",
        "woodworking",
        "garden",
        "eurorack",
        "halogen",
        "archived",
    ]

    for tag_name in seed_tags:
        duck_conn.execute(
            "INSERT INTO tags (name) VALUES (?)",
            [tag_name],
        )

    # Auto-tag based on domain/subdomain
    tag_rules = [
        ("hylograph", "subdomain = 'hylograph'"),
        ("minard", "subdomain = 'minard'"),
        ("shapedsteer", "subdomain = 'shapedsteer'"),
        ("purescript", "domain = 'programming'"),
        ("infrastructure", "domain = 'infrastructure'"),
        ("music", "domain = 'music'"),
        ("house", "domain = 'house'"),
        ("woodworking", "domain = 'woodworking'"),
        ("garden", "domain = 'garden'"),
        ("eurorack", "subdomain = 'eurorack'"),
        ("archived", "status = 'defunct'"),
    ]

    for tag_name, condition in tag_rules:
        duck_conn.execute(
            f"""
            INSERT INTO project_tags (project_id, tag_id)
            SELECT p.id, t.id
            FROM projects p, tags t
            WHERE t.name = ? AND {condition}
            """,
            [tag_name],
        )

    tag_count = duck_conn.execute("SELECT COUNT(*) FROM project_tags").fetchone()[0]
    return tag_count


def print_summary(duck_conn):
    """Print migration summary statistics."""
    print("\n=== Migration Summary ===")

    total = duck_conn.execute("SELECT COUNT(*) FROM projects").fetchone()[0]
    print(f"  Total projects: {total}")

    print("\n  By domain:")
    rows = duck_conn.execute(
        "SELECT domain, COUNT(*) AS n FROM projects GROUP BY domain ORDER BY n DESC"
    ).fetchall()
    for row in rows:
        print(f"    {row[0]:20s} {row[1]:3d}")

    print("\n  By status:")
    rows = duck_conn.execute(
        "SELECT status, COUNT(*) AS n FROM projects GROUP BY status ORDER BY n DESC"
    ).fetchall()
    for row in rows:
        print(f"    {row[0]:20s} {row[1]:3d}")

    tag_count = duck_conn.execute("SELECT COUNT(*) FROM project_tags").fetchone()[0]
    tag_types = duck_conn.execute("SELECT COUNT(*) FROM tags").fetchone()[0]
    print(f"\n  Tags: {tag_types} tag types, {tag_count} assignments")

    history_count = duck_conn.execute(
        "SELECT COUNT(*) FROM status_history"
    ).fetchone()[0]
    print(f"  Status history entries: {history_count}")


def main():
    check_dependencies()
    import duckdb

    print("Project Tracker: Seed Data Migration")
    print("=" * 50)

    # Verify source files exist
    for path, label in [
        (CATALOG_DB, "catalog.db"),
        (REPOS_DB, "repos.db"),
        (HOUSE_PROJECTS_MD, "house-projects.md"),
        (SCHEMA_SQL, "schema.sql"),
    ]:
        exists = "found" if path.exists() else "MISSING"
        print(f"  {label:25s} {exists:8s}  {path}")

    # Remove existing database if present (clean migration)
    if TRACKER_DB.exists():
        print(f"\n  Removing existing {TRACKER_DB}")
        TRACKER_DB.unlink()
    wal = TRACKER_DB.parent / (TRACKER_DB.name + ".wal")
    if wal.exists():
        wal.unlink()

    print(f"\n  Creating {TRACKER_DB}")
    duck_conn = duckdb.connect(str(TRACKER_DB))

    try:
        # Apply schema
        print("\n1. Applying schema...")
        create_schema(duck_conn)

        # Import plans from catalog.db
        print("\n2. Importing plans from catalog.db...")
        plan_count = migrate_plans(duck_conn)
        print(f"  Imported {plan_count} plans")

        # Import repos from repos.db
        print("\n3. Importing owned repos from repos.db...")
        repo_count = migrate_repos(duck_conn)
        print(f"  Imported {repo_count} repos (skipped those already covered by plans)")

        # Import house projects
        print("\n4. Importing house/woodworking/garden projects...")
        house_count = migrate_house_projects(duck_conn)
        print(f"  Imported {house_count} projects from house-projects.md")

        # Create tags
        print("\n5. Creating tags and auto-tagging...")
        tag_assignments = create_seed_tags(duck_conn)
        print(f"  Created {tag_assignments} tag assignments")

        # Summary
        print_summary(duck_conn)

        print(f"\nDone. Database written to {TRACKER_DB}")

    finally:
        duck_conn.close()


if __name__ == "__main__":
    main()
