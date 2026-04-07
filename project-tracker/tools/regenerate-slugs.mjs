// Regenerate all project slugs in the new (default) style.
// Imports the wordlists from compiled PureScript modules to stay in sync.

import duckdb from "duckdb";
import { nato } from "../output/Slug.Nato/index.js";

const DB_PATH = "./database/tracker.duckdb";
const WORD_COUNT = 4;

function generateSlug() {
  const parts = [];
  for (let i = 0; i < WORD_COUNT; i++) {
    parts.push(nato[Math.floor(Math.random() * nato.length)]);
  }
  return parts.join("-");
}

async function run() {
  const db = new duckdb.Database(DB_PATH);

  const rows = await new Promise((resolve, reject) => {
    db.all("SELECT id, name FROM projects ORDER BY id", (err, rows) => {
      if (err) reject(err);
      else resolve(rows);
    });
  });

  console.log(`Regenerating slugs for ${rows.length} projects (${WORD_COUNT} NATO words)`);

  // Drop and recreate the unique index so we can update freely
  await new Promise((resolve) => {
    db.run("DROP INDEX IF EXISTS idx_projects_slug", () => resolve());
  });

  // Clear all slugs first
  await new Promise((resolve, reject) => {
    db.run("UPDATE projects SET slug = NULL", (err) => {
      if (err) reject(err);
      else resolve();
    });
  });

  const used = new Set();
  let assigned = 0;

  for (const row of rows) {
    let slug;
    let attempts = 0;
    do {
      slug = generateSlug();
      attempts++;
    } while (used.has(slug) && attempts < 100);

    used.add(slug);
    await new Promise((resolve, reject) => {
      db.run("UPDATE projects SET slug = ? WHERE id = ?", slug, row.id, (err) => {
        if (err) reject(err);
        else resolve();
      });
    });
    console.log(`  ${String(row.id).padStart(3)}  ${slug.padEnd(38)}  ${row.name}`);
    assigned++;
  }

  // Restore unique index
  await new Promise((resolve) => {
    db.run("CREATE UNIQUE INDEX idx_projects_slug ON projects(slug)", () => resolve());
  });

  console.log(`\nRegenerated ${assigned} slugs`);
  db.close(() => {});
}

run().catch((e) => {
  console.error(e);
  process.exit(1);
});
