-- | Activity API endpoint
-- |
-- | Ranks projects by a simple activity score combining recent notes, status
-- | transitions, and attachments, each weighted by exponential decay on age.
-- |
-- | The score is intended to answer "what's live right now?" — a project with
-- | lots of notes from last week outranks one with twenty notes from a year ago.
-- | Components are returned alongside the score so callers can see *why* a
-- | project ranked where it did, not just a black-box number.
module API.Activity
  ( getActivity
  ) where

import Prelude

import Data.Int as Int
import Data.Maybe (Maybe(..), fromMaybe)
import Database.DuckDB (Database, Rows, queryAllParams)
import Effect.Aff (Aff)
import Foreign (unsafeToForeign)
import HTTPurple (Response, ok')
import HTTPurple.Headers (ResponseHeaders, headers)

jsonHeaders :: ResponseHeaders
jsonHeaders = headers
  { "Content-Type": "application/json"
  , "Access-Control-Allow-Origin": "*"
  }

foreign import buildActivityJson :: Rows -> Number -> Number -> Int -> String

-- | GET /api/activity
-- |
-- | Query params (all optional):
-- |   halflife — days for the recency half-life (default 30)
-- |   window   — max age in days to count events (default 180)
-- |   limit    — max rows (default 50, hard cap 500)
-- |   domain   — filter by project domain
-- |
-- | Score = sum over each event e in the window of
-- |   weight(e) * 2^(-age_days(e) / halflife)
-- | with weights: notes = 1.0, status transitions = 3.0, attachments = 0.5.
-- |
-- | Two guard rails against import-day inflation:
-- |   1. Status transitions exclude project-creation rows (old_status IS NULL)
-- |      unless they happened in the last 7 days, so a project gets credit for
-- |      being newly created only briefly; after that it has to earn activity
-- |      via notes/transitions.
-- |   2. Attachments are a presence signal, not a volume signal: only the
-- |      newest 3 per project contribute to the score. A project with 12
-- |      photos doesn't score 6× a project with 2 photos.
getActivity
  :: Database
  -> Maybe String -- halflife (days)
  -> Maybe String -- window (days)
  -> Maybe String -- limit
  -> Maybe String -- domain filter
  -> Aff Response
getActivity db mHalflife mWindow mLimit mDomain = do
  let halflife = clampPos 1.0 365.0 30.0 (mHalflife >>= parseNumber)
  let windowDays = clampPos 1.0 3650.0 180.0 (mWindow >>= parseNumber)
  let limit = clampInt 1 500 50 (mLimit >>= Int.fromString)
  let domainClause = case mDomain of
        Just _  -> " AND p.domain = ?"
        Nothing -> ""
  let domainParams = case mDomain of
        Just d  -> [ unsafeToForeign d ]
        Nothing -> []
  let sql = activitySql domainClause
  let params =
        [ unsafeToForeign windowDays, unsafeToForeign halflife
        , unsafeToForeign windowDays, unsafeToForeign halflife
        , unsafeToForeign windowDays, unsafeToForeign halflife
        ]
          <> domainParams
          <> [ unsafeToForeign limit ]
  rows <- queryAllParams db sql params
  ok' jsonHeaders (buildActivityJson rows halflife windowDays limit)

-- | The workhorse query. One CTE per event source aggregates counts and a
-- | decayed score; the outer SELECT joins them onto projects and orders.
-- |
-- | `current_timestamp - created_at` yields an INTERVAL; `epoch(interval)`
-- | returns its length in seconds. Dividing by 86400 gives days.
activitySql :: String -> String
activitySql domainClause =
  """
  WITH notes_agg AS (
    SELECT project_id,
      COUNT(*) FILTER (WHERE created_at >= current_timestamp - INTERVAL '7 days')  AS notes_7d,
      COUNT(*) FILTER (WHERE created_at >= current_timestamp - INTERVAL '30 days') AS notes_30d,
      COUNT(*) FILTER (WHERE created_at >= current_timestamp - INTERVAL '90 days') AS notes_90d,
      COUNT(*) FILTER (WHERE created_at >= current_timestamp - INTERVAL '30 days' AND author = 'human')  AS notes_human_30d,
      COUNT(*) FILTER (WHERE created_at >= current_timestamp - INTERVAL '30 days' AND author <> 'human') AS notes_agent_30d,
      MAX(created_at) AS last_note_at,
      COALESCE(SUM(
        POWER(2.0, -((epoch(current_timestamp - created_at)) / 86400.0) / ?)
      ) FILTER (WHERE created_at >= current_timestamp - (CAST(? AS INTEGER) * INTERVAL '1 day')), 0) AS notes_score
    FROM project_notes
    GROUP BY project_id
  ),
  -- status_history has noisy rows: updateProject logs a transition whenever
  -- the PUT body contains a status field, even if the value didn't change.
  -- We dedupe by keeping only rows where new_status differs from the previous
  -- new_status for that project (ordered by changed_at).
  status_changes AS (
    SELECT project_id, new_status, changed_at, old_status, prev_status
    FROM (
      SELECT project_id, new_status, changed_at, old_status,
        LAG(new_status) OVER (PARTITION BY project_id ORDER BY changed_at) AS prev_status
      FROM status_history
    ) t
    WHERE prev_status IS NULL OR prev_status <> new_status
  ),
  status_agg AS (
    SELECT project_id,
      COUNT(*) FILTER (WHERE changed_at >= current_timestamp - INTERVAL '30 days') AS status_changes_30d,
      MAX(changed_at) AS last_status_at,
      -- Exclude creation rows (old_status IS NULL) from the decayed score UNLESS
      -- they happened within the last 7 days — so a brand-new project registers
      -- as "fresh" for a week, but a project that was created months ago and
      -- hasn't been touched since doesn't keep coasting on its birth event.
      COALESCE(SUM(
        POWER(2.0, -((epoch(current_timestamp - changed_at)) / 86400.0) / ?)
      ) FILTER (
        WHERE changed_at >= current_timestamp - (CAST(? AS INTEGER) * INTERVAL '1 day')
          AND (old_status IS NOT NULL
               OR changed_at >= current_timestamp - INTERVAL '7 days')
      ), 0) AS status_score
    FROM status_changes
    GROUP BY project_id
  ),
  -- Attachments are a presence signal more than a volume signal — a project
  -- with 12 photos isn't necessarily more "active" than one with 2. We
  -- therefore score only the newest 3 attachments per project (by created_at
  -- desc). The full in-window count is still surfaced for display.
  attach_ranked AS (
    SELECT project_id, created_at,
      ROW_NUMBER() OVER (PARTITION BY project_id ORDER BY created_at DESC) AS rn
    FROM attachments
  ),
  attach_agg AS (
    SELECT project_id,
      COUNT(*) FILTER (WHERE created_at >= current_timestamp - INTERVAL '30 days') AS attachments_30d,
      MAX(created_at) AS last_attach_at,
      COALESCE(SUM(
        POWER(2.0, -((epoch(current_timestamp - created_at)) / 86400.0) / ?)
      ) FILTER (
        WHERE rn <= 3
          AND created_at >= current_timestamp - (CAST(? AS INTEGER) * INTERVAL '1 day')
      ), 0) AS attach_score
    FROM attach_ranked
    GROUP BY project_id
  )
  SELECT
    p.id, p.slug, p.name, p.domain, p.subdomain, p.status, p.description, p.updated_at,
    COALESCE(n.notes_7d, 0)         AS notes_7d,
    COALESCE(n.notes_30d, 0)        AS notes_30d,
    COALESCE(n.notes_90d, 0)        AS notes_90d,
    COALESCE(n.notes_human_30d, 0)  AS notes_human_30d,
    COALESCE(n.notes_agent_30d, 0)  AS notes_agent_30d,
    COALESCE(s.status_changes_30d, 0) AS status_changes_30d,
    COALESCE(a.attachments_30d, 0)    AS attachments_30d,
    n.last_note_at,
    s.last_status_at,
    a.last_attach_at,
    GREATEST(
      p.updated_at,
      COALESCE(n.last_note_at, TIMESTAMP 'epoch'),
      COALESCE(s.last_status_at, TIMESTAMP 'epoch'),
      COALESCE(a.last_attach_at, TIMESTAMP 'epoch')
    ) AS last_activity_at,
    (pin.project_id IS NOT NULL) AS pinned,
    -- Final score composition:
    --   raw_activity_score
    --     = notes_score * 1.0
    --     + status_score * 3.0
    --     + attach_score * 0.5
    -- applied to:
    --   status_multiplier  — the project's own status lifecycle dampens the
    --                        score for anything parked (someday, dormant) or
    --                        terminal (done, defunct, evolved). Active/idea/
    --                        blocked pass through at 1.0.
    --   pinned_multiplier  — an explicit `pinned` tag boosts the project
    --                        regardless of the other signals. Applied after
    --                        the status multiplier, so a pinned `done` project
    --                        floats but doesn't dominate.
    ROUND(
      ((COALESCE(n.notes_score, 0)  * 1.0
      + COALESCE(s.status_score, 0) * 3.0
      + COALESCE(a.attach_score, 0) * 0.5)
      * (CASE p.status
           WHEN 'someday' THEN 0.5
           WHEN 'dormant' THEN 0.3
           WHEN 'done'    THEN 0.2
           WHEN 'defunct' THEN 0.2
           WHEN 'evolved' THEN 0.2
           ELSE 1.0
         END)
      * (CASE WHEN pin.project_id IS NOT NULL THEN 3.0 ELSE 1.0 END)
      )::DOUBLE
    , 3) AS score
  FROM projects p
  LEFT JOIN (
    SELECT pt.project_id
    FROM project_tags pt
    JOIN tags t ON t.id = pt.tag_id
    WHERE t.name = 'pinned'
  ) pin ON pin.project_id = p.id
  LEFT JOIN notes_agg  n ON n.project_id = p.id
  LEFT JOIN status_agg s ON s.project_id = p.id
  LEFT JOIN attach_agg a ON a.project_id = p.id
  WHERE 1=1
  """ <> domainClause <>
  """
  ORDER BY score DESC NULLS LAST, last_activity_at DESC NULLS LAST
  LIMIT ?
  """

-- =============================================================================
-- Parameter parsing helpers
-- =============================================================================

parseNumber :: String -> Maybe Number
parseNumber s = case Int.fromString s of
  Just n  -> Just (Int.toNumber n)
  Nothing -> Nothing

clampPos :: Number -> Number -> Number -> Maybe Number -> Number
clampPos lo hi def mv = case mv of
  Nothing -> def
  Just v  -> if v < lo then lo else if v > hi then hi else v

clampInt :: Int -> Int -> Int -> Maybe Int -> Int
clampInt lo hi def mv = fromMaybe def do
  v <- mv
  pure (if v < lo then lo else if v > hi then hi else v)
