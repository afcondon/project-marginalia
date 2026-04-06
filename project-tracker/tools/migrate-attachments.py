#!/usr/bin/env python3
"""
Link image attachments from infovore-larder-db notes to project-tracker projects.

Reads the attachments manifest, matches note titles to project names,
and inserts file_path references into the attachments table.
"""

import json
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = SCRIPT_DIR.parent
INFOVORE_ROOT = PROJECT_ROOT.parent.parent / "infovore-larder-db"

MANIFEST = INFOVORE_ROOT / "data" / "notes" / "attachments-manifest.json"
ATTACHMENTS_DIR = INFOVORE_ROOT / "data" / "notes" / "attachments"
TRACKER_DB = PROJECT_ROOT / "database" / "tracker.duckdb"


def main():
    try:
        import duckdb
    except ImportError:
        print("Error: pip3 install duckdb")
        sys.exit(1)

    if not MANIFEST.exists():
        print(f"Manifest not found: {MANIFEST}")
        sys.exit(1)

    manifest = json.loads(MANIFEST.read_text())
    attachments = manifest["attachments"]
    print(f"Manifest: {len(attachments)} attachments")

    conn = duckdb.connect(str(TRACKER_DB))

    # Get all projects with their names
    projects = conn.execute("SELECT id, name FROM projects").fetchall()
    # Build a lookup: lowercased name -> project id
    name_to_id = {}
    for pid, name in projects:
        key = name.strip().lower()
        name_to_id[key] = pid
        # Also try truncated versions (notes titles may have been truncated)
        if len(key) > 40:
            name_to_id[key[:40]] = pid

    # Match attachments to projects by note_title
    matched = 0
    skipped = 0
    for att in attachments:
        note_title = (att.get("note_title") or "").strip()
        if not note_title:
            skipped += 1
            continue

        # Try exact match first
        pid = name_to_id.get(note_title.lower())

        # Try prefix match (note titles can be truncated with ellipsis)
        if pid is None:
            clean = note_title.rstrip("\u2026").rstrip(".")
            for key, candidate_pid in name_to_id.items():
                if key.startswith(clean.lower()[:30]):
                    pid = candidate_pid
                    break

        if pid is None:
            skipped += 1
            continue

        # Build full path to the attachment file
        dest = att.get("dest", "")
        file_path = str(ATTACHMENTS_DIR / dest)
        filename = att.get("filename", Path(dest).name)

        # Determine mime type from extension
        ext = Path(filename).suffix.lower()
        mime_map = {
            ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
            ".png": "image/png", ".gif": "image/gif",
            ".pdf": "application/pdf", ".heic": "image/heic",
        }
        mime_type = mime_map.get(ext, "application/octet-stream")

        # Only import images
        if not mime_type.startswith("image/"):
            skipped += 1
            continue

        # Check file exists
        if not Path(file_path).exists():
            skipped += 1
            continue

        # Check for duplicate
        existing = conn.execute(
            "SELECT COUNT(*) FROM attachments WHERE project_id = ? AND file_path = ?",
            [pid, file_path]
        ).fetchone()[0]
        if existing > 0:
            skipped += 1
            continue

        conn.execute(
            """INSERT INTO attachments (project_id, filename, mime_type, file_path, description)
               VALUES (?, ?, ?, ?, ?)""",
            [pid, filename, mime_type, file_path,
             f"From Apple Notes: {note_title}"]
        )
        matched += 1

    conn.close()
    print(f"Matched: {matched} image attachments linked to projects")
    print(f"Skipped: {skipped} (no match, not image, or duplicate)")


if __name__ == "__main__":
    main()
