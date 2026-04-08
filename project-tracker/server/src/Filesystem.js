// Filesystem operations for project rename/move.
// All the logic lives here so PureScript can call a single high-level function.

import fs from 'fs';
import path from 'path';
import os from 'os';
import { execSync } from 'child_process';

// The workspace root for resolving relative source_paths.
// Could become configurable later; for now it's the conventional location.
const WORKSPACE_ROOT = path.join(os.homedir(), 'work', 'afc-work');

// Resolve a source_path from the DB to an absolute path.
// If already absolute, return as-is. If relative, prepend WORKSPACE_ROOT.
function resolvePath(sourcePath) {
  if (path.isAbsolute(sourcePath)) return sourcePath;
  return path.join(WORKSPACE_ROOT, sourcePath);
}

// Convert an absolute path back to a workspace-relative path where possible.
// If the path is under WORKSPACE_ROOT, return the relative form; otherwise
// return it unchanged (keeping it absolute).
function toWorkspaceRelative(abs) {
  const rel = path.relative(WORKSPACE_ROOT, abs);
  if (rel.startsWith('..')) return abs;
  return rel;
}

// Convert a project name into a filesystem-safe directory name.
// Lowercase, spaces/underscores -> hyphens, drop chars that aren't [a-z0-9.-].
function slugifyForFs(name) {
  return name
    .toLowerCase()
    .replace(/[\s_]+/g, '-')
    .replace(/[^a-z0-9.-]/g, '')
    .replace(/-+/g, '-')
    .replace(/^-|-$/g, '');
}

function findGitRoot(start) {
  let dir = path.resolve(start);
  while (true) {
    if (fs.existsSync(path.join(dir, '.git'))) return dir;
    const parent = path.dirname(dir);
    if (parent === dir) return null;
    dir = parent;
  }
}

// "Clean enough" for a rename: only tracked-file changes matter.
// Untracked files are fine — they come along with the directory rename
// either via git mv (no effect on untracked) or fs.rename (whole dir moves).
function gitIsClean(repoRoot) {
  try {
    const out = execSync('git status --porcelain --untracked-files=no', {
      cwd: repoRoot,
      encoding: 'utf-8'
    });
    return out.trim() === '';
  } catch (e) {
    return false;
  }
}

// High-level rename: given the current source_path and the desired new
// human-readable project name, do the right thing on disk.
//
// Returns one of:
//   { kind: "skipped",   reason: "source path not on disk" }
//   { kind: "skipped",   reason: "source is a file, not a directory" }
//   { kind: "renamed",   newPath: "...", method: "git mv" | "fs.rename" }
//   { kind: "error",     error: "..." }
//
// In all "skipped" and "renamed" cases, the caller should still update the
// project name in the DB. In "renamed" cases, the caller should also update
// source_path to newPath.
export const renameProjectDirectory_ = (sourcePath) => (newName) => () => {
  if (!sourcePath || sourcePath === "") {
    return { kind: "skipped", reason: "no source path set", newPath: "", method: "", error: "" };
  }

  const absSource = resolvePath(sourcePath);

  let stat;
  try {
    stat = fs.statSync(absSource);
  } catch (e) {
    return { kind: "skipped", reason: "source path not on disk: " + absSource, newPath: "", method: "", error: "" };
  }

  if (!stat.isDirectory()) {
    return { kind: "skipped", reason: "source is a file, not a directory", newPath: "", method: "", error: "" };
  }

  // Compute new path: same parent dir, slugified new name as the leaf
  const newDirName = slugifyForFs(newName);
  if (!newDirName) {
    return { kind: "error", reason: "", newPath: "", method: "", error: "new name has no usable characters for a directory" };
  }
  const parent = path.dirname(absSource);
  const absNewPath = path.join(parent, newDirName);

  if (absNewPath === absSource) {
    return { kind: "skipped", reason: "new directory name equals current name", newPath: "", method: "", error: "" };
  }

  if (fs.existsSync(absNewPath)) {
    return { kind: "error", reason: "", newPath: "", method: "", error: "destination already exists: " + absNewPath };
  }

  // Find git context
  const repoRoot = findGitRoot(absSource);
  if (repoRoot && !gitIsClean(repoRoot)) {
    return {
      kind: "error",
      reason: "",
      newPath: "",
      method: "",
      error: "git working tree is dirty in " + repoRoot + " — commit or stash first"
    };
  }

  try {
    let method;
    if (repoRoot && repoRoot !== path.resolve(absSource)) {
      // Source is inside a git repo (not the repo root itself) — use git mv
      const oldRel = path.relative(repoRoot, absSource);
      const newRel = path.relative(repoRoot, absNewPath);
      execSync(
        `git mv ${JSON.stringify(oldRel)} ${JSON.stringify(newRel)}`,
        { cwd: repoRoot }
      );
      method = "git mv";
    } else {
      // Standalone repo or non-repo directory — plain rename
      fs.renameSync(absSource, absNewPath);
      method = "fs.rename";
    }

    // Return the new path in the same form as the original (relative if the
    // original was relative and the destination is also under WORKSPACE_ROOT).
    const relNewPath = path.isAbsolute(sourcePath)
      ? absNewPath
      : toWorkspaceRelative(absNewPath);

    return { kind: "renamed", reason: "", newPath: relNewPath, method, error: "" };
  } catch (e) {
    return { kind: "error", reason: "", newPath: "", method: "", error: String(e.message || e) };
  }
};
