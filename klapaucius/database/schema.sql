-- =============================================================================
-- Klapaucius Schema — blog workbench
-- =============================================================================
--
-- A blog authoring workbench that pulls source material from multiple
-- archives (Marginalia projects, infovore music/photos/books/concerts)
-- and manages the editorial lifecycle from idea to publication.
--
-- Posts are stored on disk as /<category>/<slug>/index.md + assets.
-- This database tracks editorial state, not content.
--
-- =============================================================================

CREATE SEQUENCE IF NOT EXISTS seq_posts START 1;

CREATE TABLE IF NOT EXISTS blog_posts (
  id          INTEGER PRIMARY KEY DEFAULT nextval('seq_posts'),
  category    TEXT NOT NULL,       -- projects, music, photos, concerts, books, podcasts, cooking, freestanding
  slug        TEXT NOT NULL,       -- filesystem-safe identifier
  title       TEXT NOT NULL,
  status      TEXT NOT NULL DEFAULT 'wanted',  -- wanted, wanted_priority, drafted, published, not_needed
  source_type TEXT,                -- marginalia, infovore_music, infovore_photos, infovore_books, infovore_concerts, freestanding
  source_id   TEXT,                -- external identifier (project slug, track dedup_key, image_id, etc.)
  source_meta TEXT,                -- JSON blob of source metadata snapshot (artist, album, capture_time, etc.)
  word_count  INTEGER DEFAULT 0,
  has_file    BOOLEAN DEFAULT FALSE,
  created_at  TIMESTAMP DEFAULT current_timestamp,
  updated_at  TIMESTAMP DEFAULT current_timestamp,
  UNIQUE(category, slug)
);

CREATE INDEX IF NOT EXISTS idx_posts_status ON blog_posts(status);
CREATE INDEX IF NOT EXISTS idx_posts_category ON blog_posts(category);
CREATE INDEX IF NOT EXISTS idx_posts_source ON blog_posts(source_type, source_id);
