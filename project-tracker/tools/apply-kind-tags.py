#!/usr/bin/env python3
"""
Apply kind/output/language tags to projects based on source_path patterns.

Uses three orthogonal tag dimensions:
  - KIND: library, showcase, app, api-server, cli, port, website, skill,
          deploy-config, umbrella, data-archive
  - OUTPUT: js-bundle, static-site, wasm, native-bin, native-lib, docker-image,
            registry-package, markdown-doc
  - LANGUAGE: purescript, rust, python, javascript, erlang, haskell

Uses the existing tagging API (POST /api/projects/:id/tags).
"""

import json
import sys
import urllib.request

API = "http://localhost:3100"


def get_all_projects():
    # The list endpoint doesn't include source_path; fetch each detail individually.
    data = json.loads(urllib.request.urlopen(f"{API}/api/projects").read())
    summaries = data["projects"]
    full = []
    for s in summaries:
        detail = json.loads(urllib.request.urlopen(f"{API}/api/projects/{s['id']}").read())
        full.append(detail)
    return full


def add_tag(project_id, tag):
    req = urllib.request.Request(
        f"{API}/api/projects/{project_id}/tags",
        data=json.dumps({"tag": tag}).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        urllib.request.urlopen(req).read()
        return True
    except Exception as e:
        print(f"  !! failed to add {tag} to #{project_id}: {e}")
        return False


def classify(project):
    """Return a set of tags to add to this project based on its attributes."""
    pid = project["id"]
    sp = project.get("sourcePath") or ""
    name = project["name"]
    subdomain = project.get("subdomain") or ""
    current_tags = set(project.get("tags") or [])
    existing_all_lower = {t.lower() for t in current_tags}

    to_add = set()

    # --- KIND dimension ---
    if subdomain == "rollup":
        to_add.add("umbrella")
        return to_add  # rollups get ONLY the umbrella tag from this pass

    if sp.startswith("purescript-hylograph-libs/"):
        to_add.update({"library", "registry-package", "purescript"})

    elif sp.startswith("purescript-hylograph-showcases/"):
        to_add.update({"showcase", "js-bundle", "purescript"})

    elif sp.startswith("purescript-ports/"):
        # Leaf ports projects (already tagged as port)
        to_add.update({"port", "registry-package", "purescript"})

    elif sp.startswith("purescript-backends/"):
        to_add.update({"port", "purescript"})
        # purescript-python-new — produces Python code as output
        if "python" in sp.lower():
            to_add.add("python")

    elif sp.startswith("CodeExplorer/") or "minard" in sp.lower():
        to_add.update({"app", "purescript"})

    elif sp.startswith("ShapedSteer/"):
        # ShapedSteer plans are markdown docs, not apps themselves
        if sp.endswith(".md"):
            to_add.update({"markdown-doc", "purescript"})
        else:
            to_add.update({"app", "purescript"})

    elif "purescript-polyglot" in sp and not sp.endswith(".md"):
        to_add.update({"website", "purescript"})

    elif sp.endswith(".md") and "purescript-polyglot" in sp:
        # Plans and worklogs stored as markdown in polyglot
        to_add.update({"markdown-doc"})

    elif sp.startswith("hylograph-sites"):
        to_add.update({"website", "static-site", "deploy-config"})

    elif sp.startswith("hylograph-howto"):
        to_add.update({"website", "static-site"})

    elif sp.startswith("GitHub/"):
        # External clones — leave as-is, they already have external-reference
        pass

    elif sp.startswith("archived/"):
        # Archived — leave as-is
        pass

    # --- Special cases by name ---
    name_lower = name.lower()
    if name_lower == "project tracker":
        to_add.update({"app", "purescript", "api-server"})
    elif name_lower == "claude inbox":
        # Meta-project, not code
        pass
    elif name_lower.startswith("minard"):
        # Minard has Rust components too
        to_add.add("rust")

    # Remove tags that already exist
    new_tags = to_add - existing_all_lower
    return new_tags


def classify_artifacts(project):
    """Second-pass artifact tags — inferred from the project's existing kind tags and path."""
    sp = project.get("sourcePath") or ""
    current_tags = {t.lower() for t in (project.get("tags") or [])}
    to_add = set()

    # Registry packages: anything in hylograph-libs or purescript-ports is published
    if sp.startswith("purescript-hylograph-libs/") or sp.startswith("purescript-ports/"):
        to_add.add("registry-package")

    # Showcases bundle to JS for the browser
    if sp.startswith("purescript-hylograph-showcases/"):
        to_add.add("js-bundle")

    # WASM-specific projects
    if "wasm" in sp.lower():
        to_add.add("wasm")

    # Websites that are statically generated
    if sp.startswith("hylograph-sites") or sp.startswith("hylograph-howto"):
        to_add.add("static-site")

    # Markdown plan files — only for actual planning/docs directories
    # (not the shared house-projects.md extraction source)
    if sp.endswith(".md") and ("/docs/" in sp or "/plans/" in sp):
        to_add.add("markdown-doc")

    # Dockerfile present (many showcases have them for deployment)
    # Already handled by earlier extract — "docker" tag exists for those

    return to_add - current_tags


def main():
    projects = get_all_projects()
    print(f"Analyzing {len(projects)} projects...")

    classifier = classify_artifacts if "--artifacts" in sys.argv else classify
    label = "artifact" if "--artifacts" in sys.argv else "kind"

    plan = []  # list of (pid, name, tags_to_add)
    for p in projects:
        new_tags = classifier(p)
        if new_tags:
            plan.append((p["id"], p["name"], sorted(new_tags)))

    print(f"\nPlan ({label}): tag {len(plan)} projects\n")

    if not plan:
        print("Nothing to do — all projects already have their tags.")
        return

    for pid, name, tags in plan[:50]:
        print(f"  #{pid:3d}  {name[:40]:40s}  +{','.join(tags)}")
    if len(plan) > 50:
        print(f"  ... and {len(plan) - 50} more")

    if "--apply" not in sys.argv:
        print("\n(dry run — pass --apply to execute)")
        return

    print("\nApplying...")
    total = 0
    for pid, _name, tags in plan:
        for t in tags:
            if add_tag(pid, t):
                total += 1
    print(f"Applied {total} tag links")


if __name__ == "__main__":
    main()
