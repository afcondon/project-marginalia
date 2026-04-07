#!/usr/bin/env python3
"""Apply description and tag proposals to the database."""

import json
import sys
import duckdb

DB_PATH = "database/tracker.duckdb"
PROPOSALS_PATH = "/tmp/proposals.json"

# IDs to skip (descriptions are bad/already good)
SKIP_IDS = {
    84,   # purescript-eco-saw — README starts with a count, not useful
    91,   # purescript-diagrams — already updated as port
    92,   # purescript-linear — already updated as port
    93,   # purescript-machines — already updated as port
    121,  # Project Tracker — already has good description
}


def main():
    proposals = json.load(open(PROPOSALS_PATH))
    conn = duckdb.connect(DB_PATH)

    # Get existing tags
    existing_tags = {row[0]: row[1] for row in conn.execute("SELECT name, id FROM tags").fetchall()}

    descs_updated = 0
    tags_added = 0
    tags_created = 0

    for p in proposals:
        if p["id"] in SKIP_IDS:
            continue

        # Update description (only if currently empty/None)
        if p["proposed_description"] and not p["current_description"]:
            conn.execute(
                "UPDATE projects SET description = ?, updated_at = current_timestamp WHERE id = ?",
                [p["proposed_description"], p["id"]]
            )
            descs_updated += 1

        # Add tags
        for tag_name in p["tags"]:
            # Create tag if needed
            if tag_name not in existing_tags:
                conn.execute("INSERT INTO tags (name) VALUES (?)", [tag_name])
                new_id = conn.execute("SELECT id FROM tags WHERE name = ?", [tag_name]).fetchone()[0]
                existing_tags[tag_name] = new_id
                tags_created += 1

            tag_id = existing_tags[tag_name]
            # Skip if already linked
            existing = conn.execute(
                "SELECT 1 FROM project_tags WHERE project_id = ? AND tag_id = ?",
                [p["id"], tag_id]
            ).fetchone()
            if not existing:
                conn.execute(
                    "INSERT INTO project_tags (project_id, tag_id) VALUES (?, ?)",
                    [p["id"], tag_id]
                )
                tags_added += 1

    conn.close()
    print(f"Descriptions updated: {descs_updated}")
    print(f"Tags added: {tags_added}")
    print(f"New tags created: {tags_created}")


if __name__ == "__main__":
    main()
