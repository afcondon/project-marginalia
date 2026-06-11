-- | Statistics API endpoint
-- |
-- | Returns aggregate counts by domain/status using the domain_status_counts
-- | view, federated with the Infovore markdown life-projects so the counts
-- | agree with the federated Register.
module API.Stats
  ( getStats
  ) where

import Prelude

import API.Infovore as Infovore
import Database.DuckDB (Database, queryAll)
import Effect.Aff (Aff)
import Effect.Class (liftEffect)
import HTTPurple (Response, ok')
import HTTPurple.Headers (ResponseHeaders, headers)

-- | JSON content type header with CORS
jsonHeaders :: ResponseHeaders
jsonHeaders = headers
  { "Content-Type": "application/json"
  , "Access-Control-Allow-Origin": "*"
  }

-- =============================================================================
-- GET /api/stats
-- =============================================================================

-- | Get overall statistics: domain/status breakdown, total counts — DB
-- | aggregates plus the markdown life-projects, deduped by project id.
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
  -- Project ids, for the federated dedupe-by-id bridge
  idRows <- queryAll db "SELECT id FROM projects"
  json <- liftEffect $ Infovore.federatedStatsJson domainStatusRows totalsRows domainRows idRows
  ok' jsonHeaders json
