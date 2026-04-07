#!/usr/bin/env python3
"""
Extract project descriptions and suggest tags from README files,
spago.yaml descriptions, and source code structure.

Outputs a proposal as JSON for review before applying.
"""

import json
import os
import re
import sys
import duckdb
from pathlib import Path

DB_PATH = "database/tracker.duckdb"
WORKSPACE_ROOT = Path("/Users/afc/work/afc-work")


def strip_html(text: str) -> str:
    """Remove HTML tags."""
    return re.sub(r"<[^>]+>", "", text)


def strip_md_links(text: str) -> str:
    """Replace [label](url) with label."""
    return re.sub(r"\[([^\]]+)\]\([^\)]+\)", r"\1", text)


def extract_readme_summary(readme_path: Path) -> str | None:
    """Extract a meaningful summary from a README.

    Strategy:
      - Skip headings, badges, HTML blocks, code fences, tables
      - Take the first non-empty paragraph that's actual prose
      - Strip HTML, markdown links to plain text
      - Limit to ~280 chars at a sentence boundary
    """
    if not readme_path.exists():
        return None

    text = readme_path.read_text(encoding="utf-8", errors="ignore")
    lines = text.split("\n")

    paragraphs = []
    current = []
    in_code_fence = False
    in_html_block = False

    for line in lines:
        stripped = line.strip()

        # Code fence toggle
        if stripped.startswith("```"):
            in_code_fence = not in_code_fence
            if current:
                paragraphs.append(" ".join(current))
                current = []
            continue
        if in_code_fence:
            continue

        # HTML block detection (lines starting with HTML tags)
        if re.match(r"^<(p|div|h[1-6]|img|a|center|table|br|hr|span)\b", stripped, re.IGNORECASE):
            in_html_block = True
        if in_html_block:
            if "</p>" in stripped or "</div>" in stripped or "</center>" in stripped:
                in_html_block = False
            continue

        # Empty line = paragraph break
        if not stripped:
            if current:
                paragraphs.append(" ".join(current))
                current = []
            continue

        # Skip headings, badges, images, rules, table rows
        if stripped.startswith("#"):
            if current:
                paragraphs.append(" ".join(current))
                current = []
            continue
        if stripped.startswith("![") or stripped.startswith("[!["):
            continue
        if stripped == "---" or stripped.startswith("==="):
            continue
        if stripped.startswith("|"):
            continue

        current.append(stripped)

    if current:
        paragraphs.append(" ".join(current))

    # Find the first paragraph with prose
    for para in paragraphs:
        # Strip HTML and markdown links
        clean = strip_html(strip_md_links(para)).strip()
        # Strip leading markdown markers (>, -, *, **)
        clean = re.sub(r"^[>\-*]+\s*", "", clean)
        # Strip wrapping **bold**
        clean = re.sub(r"\*\*([^*]+)\*\*", r"\1", clean)
        # Strip backticks
        clean = re.sub(r"`([^`]+)`", r"\1", clean)
        # Collapse whitespace
        clean = re.sub(r"\s+", " ", clean).strip()

        # Reject if too short, too HTML-y, or starts with common non-prose patterns
        if len(clean) < 30:
            continue
        if clean.startswith("!") or clean.startswith("["):
            continue
        # Must be majority letters (not symbols/code)
        letter_ratio = sum(c.isalpha() or c.isspace() for c in clean) / len(clean)
        if letter_ratio < 0.75:
            continue
        # Trim to sentence boundary
        if len(clean) <= 280:
            return clean
        truncated = clean[:280]
        last_period = truncated.rfind(". ")
        if last_period > 100:
            return truncated[:last_period + 1]
        return truncated.rsplit(" ", 1)[0] + "..."

    return None


def extract_spago_description(spago_path: Path) -> str | None:
    """Extract the description: field from a spago.yaml file."""
    if not spago_path.exists():
        return None
    text = spago_path.read_text(encoding="utf-8", errors="ignore")
    match = re.search(r'^\s*description:\s*"([^"]+)"', text, re.MULTILINE)
    if match:
        return match.group(1)
    match = re.search(r"^\s*description:\s*'([^']+)'", text, re.MULTILINE)
    if match:
        return match.group(1)
    return None


def detect_tags(source_path: str, full_path: Path) -> list[str]:
    """Suggest tags based on path structure and project files.

    Conservative — relies on directory structure and file presence,
    not on free-form README text matching (which is too noisy).
    """
    tags = set()
    sp = source_path

    # Path-based tags (highest signal)
    if "purescript-hylograph-libs" in sp:
        tags.update(["hylograph", "library", "purescript"])
    elif "purescript-hylograph-showcases" in sp:
        tags.update(["hylograph", "showcase", "purescript"])
    elif sp.startswith("hylograph-howto") or sp.startswith("hylograph-sites"):
        tags.update(["hylograph"])
    elif "purescript-ports" in sp:
        tags.update(["port", "purescript"])
    elif "purescript-backends" in sp:
        tags.update(["purescript", "backend"])
    elif "ShapedSteer" in sp:
        tags.update(["shapedsteer", "purescript"])
    elif "CodeExplorer" in sp or "minard" in sp.lower():
        tags.update(["minard", "purescript"])

    # External clones — tag as such, no content tags
    if sp.startswith("GitHub/"):
        tags.add("external-reference")
        return sorted(tags)
    if sp.startswith("archived/"):
        tags.add("archived")

    # File-presence signals (much more reliable than text matching)
    if (full_path / "spago.yaml").exists() or (full_path / "spago.dhall").exists():
        tags.add("purescript")
    if (full_path / "Cargo.toml").exists():
        tags.add("rust")
    if (full_path / "pyproject.toml").exists() or (full_path / "setup.py").exists():
        tags.add("python")
    if (full_path / "Dockerfile").exists() or (full_path / "docker-compose.yml").exists():
        tags.update(["docker", "infrastructure"])

    # Halogen detection — check spago.yaml deps if it's a PureScript project
    spago_yaml = full_path / "spago.yaml"
    if spago_yaml.exists():
        try:
            content = spago_yaml.read_text()
            if "halogen" in content.lower():
                tags.add("halogen")
            if "purerl" in content.lower():
                tags.update(["purerl", "erlang"])
            if "duckdb" in content.lower():
                tags.add("duckdb")
        except Exception:
            pass

    return sorted(tags)


def main():
    conn = duckdb.connect(DB_PATH, read_only=True)
    rows = conn.execute("""
        SELECT id, slug, name, repo, source_path, description
        FROM projects
        WHERE domain = 'programming'
        ORDER BY id
    """).fetchall()
    conn.close()

    proposals = []
    for pid, slug, name, repo, source_path, current_desc in rows:
        if not source_path:
            continue

        # Skip external clones — these aren't the user's projects
        if source_path.startswith("GitHub/"):
            continue

        full_path = WORKSPACE_ROOT / source_path
        # If source_path points to a markdown file, use its parent
        if full_path.suffix == ".md":
            continue  # already a description doc

        readme = full_path / "README.md"
        readme_text = None
        new_desc = None
        source = None

        # 1. Try README
        if readme.exists():
            readme_text = readme.read_text(encoding="utf-8", errors="ignore")
            new_desc = extract_readme_summary(readme)
            if new_desc:
                source = "README.md"

        # 2. Try spago.yaml
        if not new_desc:
            spago_desc = extract_spago_description(full_path / "spago.yaml")
            if spago_desc:
                new_desc = spago_desc
                source = "spago.yaml"

        # 3. Try package.json
        if not new_desc:
            pkg_path = full_path / "package.json"
            if pkg_path.exists():
                try:
                    pkg = json.loads(pkg_path.read_text())
                    if pkg.get("description"):
                        new_desc = pkg["description"]
                        source = "package.json"
                except Exception:
                    pass

        if not new_desc and not current_desc:
            # Skip projects with no extractable description
            continue

        tags = detect_tags(source_path, full_path)

        proposals.append({
            "id": pid,
            "slug": slug,
            "name": name,
            "current_description": current_desc,
            "proposed_description": new_desc,
            "source": source,
            "tags": tags,
        })

    print(json.dumps(proposals, indent=2))


if __name__ == "__main__":
    main()
