import { spawn } from 'child_process';
import os from 'os';
import path from 'path';

// Duplicated from Projects.js — PureScript FFI files can't import each
// other since the compiler copies them to output/foreign.js per module.
export const getRowString_ = (key) => (row) => {
  if (row == null) return '';
  const v = row[key];
  return v == null ? '' : String(v);
};

// Base directory for resolving relative source paths.
const BASE_DIR = path.join(os.homedir(), 'work', 'afc-work');

// Resolve a source_path from the DB to an absolute filesystem path.
// Absolute paths pass through; relative paths get BASE_DIR prepended.
export const resolveSourcePath_ = (sourcePath) => {
  if (!sourcePath || sourcePath.trim() === '') return null;
  if (path.isAbsolute(sourcePath)) return sourcePath;
  return path.join(BASE_DIR, sourcePath);
};

// Open a resolved absolute path in one of the supported apps.
// Returns { kind: "ok" | "error", path, error }.
export const openInApp_ = (app) => (absPath) => () => {
  if (process.platform !== 'darwin') {
    return { kind: 'error', path: absPath, error: 'Only supported on macOS' };
  }

  let args;
  switch (app) {
    case 'finder':
      args = [absPath];
      break;
    case 'vscode':
      args = ['-a', 'Visual Studio Code', absPath];
      break;
    case 'iterm':
      args = ['-a', 'iTerm', absPath];
      break;
    default:
      return { kind: 'error', path: absPath, error: `Unknown app: ${app}` };
  }

  try {
    const child = spawn('open', args, { detached: true, stdio: 'ignore' });
    child.on('error', (err) => {
      console.error(`openInApp(${app}) spawn error:`, (err && err.message) || err);
    });
    child.unref();
    return { kind: 'ok', path: absPath, error: '' };
  } catch (e) {
    return { kind: 'error', path: absPath, error: String((e && e.message) || e) };
  }
};
