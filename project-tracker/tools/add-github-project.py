#!/usr/bin/env python3
"""
Clone a GitHub repo and add it to the project tracker.

Usage:
    python3 tools/add-github-project.py <github-url> [--status STATUS] [--domain DOMAIN]

Examples:
    python3 tools/add-github-project.py https://github.com/saleh/some-repo
    python3 tools/add-github-project.py git@github.com:user/repo.git --status idea

What it does:
    1. Parses the GitHub URL into owner/repo
    2. Clones to ~/work/afc-work/GitHub/{repo}
    3. Extracts a description from the README
    4. Detects tags from the project structure
    5. POSTs to the project tracker API to create the project entry
"""

import argparse
import json
import re
import subprocess
import sys
import urllib.request
from pathlib import Path

# Reuse the extraction helpers from the existing tool
sys.path.insert(0, str(Path(__file__).parent))
from importlib import import_module
extract_mod = import_module("extract-descriptions")

API_BASE = "http://localhost:3100"
CLONE_ROOT = Path.home() / "work" / "afc-work" / "GitHub"


def parse_github_url(url: str) -> tuple[str, str]:
    """Parse a GitHub URL into (owner, repo). Handles https and ssh forms."""
    # https://github.com/owner/repo[.git][/...]
    m = re.match(r"https?://github\.com/([^/]+)/([^/]+?)(?:\.git)?(?:/.*)?$", url)
    if m:
        return m.group(1), m.group(2)
    # git@github.com:owner/repo[.git]
    m = re.match(r"git@github\.com:([^/]+)/([^/]+?)(?:\.git)?$", url)
    if m:
        return m.group(1), m.group(2)
    raise ValueError(f"Not a recognised GitHub URL: {url}")


def clone_repo(owner: str, repo: str) -> Path:
    """Clone with `gh repo clone` (handles auth) into ~/work/afc-work/GitHub/{repo}."""
    CLONE_ROOT.mkdir(parents=True, exist_ok=True)
    dest = CLONE_ROOT / repo

    if dest.exists():
        print(f"  {dest} already exists — skipping clone")
        return dest

    print(f"  Cloning {owner}/{repo} -> {dest}")
    try:
        subprocess.run(
            ["gh", "repo", "clone", f"{owner}/{repo}", str(dest)],
            check=True,
            capture_output=True,
            text=True,
        )
    except subprocess.CalledProcessError as e:
        print(f"  gh failed, trying git clone:\n  {e.stderr}")
        subprocess.run(
            ["git", "clone", f"https://github.com/{owner}/{repo}.git", str(dest)],
            check=True,
        )
    return dest


def post_project(payload: dict) -> dict:
    req = urllib.request.Request(
        f"{API_BASE}/api/projects",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read())


def add_tags(project_id: int, tags: list[str]) -> None:
    """Add tags to a project via the API."""
    for tag in tags:
        req = urllib.request.Request(
            f"{API_BASE}/api/projects/{project_id}/tags",
            data=json.dumps({"tag": tag}).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            urllib.request.urlopen(req).read()
            print(f"  + tag: {tag}")
        except Exception as e:
            print(f"  ! failed to add tag {tag}: {e}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("url", help="GitHub URL")
    parser.add_argument("--status", default="active", help="Initial status (default: active)")
    parser.add_argument("--domain", default="programming", help="Domain (default: programming)")
    parser.add_argument("--subdomain", default=None, help="Subdomain")
    args = parser.parse_args()

    print(f"Adding project from {args.url}")
    try:
        owner, repo = parse_github_url(args.url)
    except ValueError as e:
        print(f"Error: {e}")
        sys.exit(1)

    print(f"  owner={owner} repo={repo}")

    dest = clone_repo(owner, repo)

    # Extract description
    readme = dest / "README.md"
    description = None
    if readme.exists():
        description = extract_mod.extract_readme_summary(readme)
    if not description:
        spago_desc = extract_mod.extract_spago_description(dest / "spago.yaml")
        if spago_desc:
            description = spago_desc

    if description:
        print(f"  description: {description[:100]}...")
    else:
        print(f"  description: (none extracted)")

    # Detect tags
    source_path_rel = f"GitHub/{repo}"
    tags = extract_mod.detect_tags(source_path_rel, dest)
    print(f"  tags: {tags}")

    # POST to API
    payload = {
        "name": repo,
        "domain": args.domain,
        "status": args.status,
        "repo": repo,
        "sourcePath": source_path_rel,
        "sourceUrl": f"https://github.com/{owner}/{repo}",
    }
    if args.subdomain:
        payload["subdomain"] = args.subdomain
    if description:
        payload["description"] = description

    result = post_project(payload)
    project = result["projects"][0]
    print()
    print(f"Created project #{project['id']} ({project.get('slug', '')})")
    print(f"  {project['name']}")

    # Add tags via API
    if tags:
        add_tags(project["id"], tags)


if __name__ == "__main__":
    main()
