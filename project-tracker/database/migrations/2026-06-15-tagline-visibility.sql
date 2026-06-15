-- Migration: tagline + visibility columns on projects
-- Date: 2026-06-15
--
-- Rationale
-- ---------
-- Two curation fields for the Minard-for-Marginalia map (#235), which renders the
-- project graph as a zoomable treemap served both as a public showcase on
-- andrewcondon.com and as an in-house "newspaper" view inside the tracker.
--
--   tagline    — the editorial "kicker": a one-line, intrinsic definition of the
--                project, shorter and tighter than `description` (the Claude-
--                maintained agent-bootstrap summary). Human-authored. Drives the
--                kicker line above each map cell.
--   visibility — 'public' | 'private'. The structure/style seam's exclusion half:
--                the in-house newspaper shows everything; the public website tree
--                drops projects marked 'private'. Defaults to 'public'.
--
-- Applied automatically at server boot via the idempotent ALTERs in
-- server/src/Main.purs and database/schema.sql. This file is the record of record.

ALTER TABLE projects ADD COLUMN IF NOT EXISTS tagline TEXT;
ALTER TABLE projects ADD COLUMN IF NOT EXISTS visibility TEXT DEFAULT 'public';
