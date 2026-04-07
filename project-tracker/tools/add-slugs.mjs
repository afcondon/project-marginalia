// One-time migration: add slug column to projects, backfill all existing rows.
// Uses the curated wordlists from the compiled PureScript modules.

import duckdb from "duckdb";
import { adjectives } from "../output/Slug.Adjectives/index.js";
import { animals } from "../output/Slug.Animals/index.js";

const DB_PATH = "./database/tracker.duckdb";

function generateSlug() {
  const a = adjectives[Math.floor(Math.random() * adjectives.length)];
  const b = animals[Math.floor(Math.random() * animals.length)];
  const c = animals[Math.floor(Math.random() * animals.length)];
  return `${a}-${b}-${c}`;
}

async function run() {
  const db = new duckdb.Database(DB_PATH);

  // Add slug column if not present (DuckDB doesn't support IF NOT EXISTS on ADD COLUMN reliably)
  await new Promise((resolve) => {
    db.run("ALTER TABLE projects ADD COLUMN slug TEXT", () => resolve());
  });

  // Get all projects without slugs
  const rows = await new Promise((resolve, reject) => {
    db.all("SELECT id, name FROM projects WHERE slug IS NULL OR slug = ''", (err, rows) => {
      if (err) reject(err);
      else resolve(rows);
    });
  });

  console.log(`Found ${rows.length} projects to slugify`);

  const usedSlugs = new Set();
  // Pre-load existing slugs to avoid collisions
  await new Promise((resolve, reject) => {
    db.all("SELECT slug FROM projects WHERE slug IS NOT NULL AND slug != ''", (err, existing) => {
      if (err) reject(err);
      else {
        existing.forEach((r) => usedSlugs.add(r.slug));
        resolve();
      }
    });
  });

  let assigned = 0;
  for (const row of rows) {
    let slug;
    let attempts = 0;
    do {
      slug = generateSlug();
      attempts++;
    } while (usedSlugs.has(slug) && attempts < 100);

    usedSlugs.add(slug);
    await new Promise((resolve, reject) => {
      db.run("UPDATE projects SET slug = ? WHERE id = ?", slug, row.id, (err) => {
        if (err) reject(err);
        else resolve();
      });
    });
    console.log(`  ${row.id} -> ${slug}  (${row.name})`);
    assigned++;
  }

  console.log(`\nAssigned ${assigned} slugs`);

  // Add unique constraint via index (DuckDB way)
  await new Promise((resolve) => {
    db.run("CREATE UNIQUE INDEX IF NOT EXISTS idx_projects_slug ON projects(slug)", () => resolve());
  });

  db.close(() => {});
}

run().catch((e) => {
  console.error(e);
  process.exit(1);
});
