-- | Statistics API endpoint
-- |
-- | Returns aggregate counts by domain/status using the domain_status_counts view.
module API.Stats
  ( getStats
  ) where

import Prelude

import Database.DuckDB (Database, queryAll)
import Effect.Aff (Aff)
import Foreign (Foreign)
import HTTPurple (Response, ok')
import HTTPurple.Headers (ResponseHeaders, headers)

-- | JSON content type header with CORS
jsonHeaders :: ResponseHeaders
jsonHeaders = headers
  { "Content-Type": "application/json"
  , "Access-Control-Allow-Origin": "*"
  }

-- =============================================================================
-- FFI Imports
-- =============================================================================

foreign import buildStatsJson :: Array Foreign -> Array Foreign -> Array Foreign -> String

-- =============================================================================
-- GET /api/stats
-- =============================================================================

-- | Get overall statistics: domain/status breakdown, total counts.
getStats :: Database -> Aff Response
getStats db = do
  -- Domain/status breakdown
  domainStatusRows <- queryAll db "SELECT * FROM domain_status_counts ORDER BY domain, status"
  -- Total counts
  totalsRows <- queryAll db
    """SELECT
         (SELECT COUNT(*) FROM projects) AS total_projects,
         (SELECT COUNT(*) FROM tags) AS total_tags,
         (SELECT COUNT(*) FROM dependencies) AS total_dependencies,
         (SELECT COUNT(*) FROM project_notes) AS total_notes"""
  -- Distinct domains
  domainRows <- queryAll db "SELECT DISTINCT domain FROM projects ORDER BY domain"
  ok' jsonHeaders (buildStatsJson domainStatusRows totalsRows domainRows)
