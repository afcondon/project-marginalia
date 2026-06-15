-- | GET /api/tree — serves the Minard "tree.json" contract live from the DB.
-- |
-- | The server-side promotion of cloudflare-sites/andrewcondon/working/tree.mjs: runs two
-- | queries (projects with the semantic columns the tree needs; the dependency graph) and
-- | hands the rows to the JS builder (Tree.js), which holds the proven selection/shape logic.
-- | Query params mirror the generator's env switches:
-- |   ?tag=flagship    -> curated flat tree (synthetic root + tagged projects)
-- |   ?group=domain    -> full forest grouped by domain (two rect tiers)
-- |   ?root=125        -> subtree rooted at one project
-- |   ?publicOnly=1    -> drop projects marked visibility='private' (public showcase)
-- | Default (no params) is the ungrouped full forest.
module API.Tree
  ( getTree
  ) where

import Prelude

import Data.Maybe (Maybe, fromMaybe)
import Database.DuckDB (Database, Rows, queryAllParams)
import Effect.Aff (Aff)
import Foreign (Foreign)
import HTTPurple (Response, ok')
import HTTPurple.Headers (ResponseHeaders, headers)

jsonHeaders :: ResponseHeaders
jsonHeaders = headers
  { "Content-Type": "application/json"
  , "Access-Control-Allow-Origin": "*"
  }

foreign import buildTreeJson :: Rows -> Rows -> String -> String -> String -> String -> String

noParams :: Array Foreign
noParams = []

getTree :: Database -> Maybe String -> Maybe String -> Maybe String -> Maybe String -> Aff Response
getTree db mTag mGroup mRoot mPublicOnly = do
  -- One query for the whole project set with the columns the tree needs (tags aggregated,
  -- cover via the attachments join, repo/source_url for the github-link target). The tree
  -- shape is reconstructed from parent_id in the JS builder.
  projectRows <- queryAllParams db projectSql noParams
  depRows <- queryAllParams db depSql noParams
  let s = fromMaybe ""
  ok' jsonHeaders (buildTreeJson projectRows depRows (s mTag) (s mGroup) (s mRoot) (s mPublicOnly))
  where
  projectSql =
    """SELECT p.id, p.slug, p.parent_id, p.name, p.domain, p.status,
              p.tagline, p.visibility, p.repo, p.source_url, p.description,
              a_cover.file_path AS cover_path,
              STRING_AGG(DISTINCT t.name, ', ' ORDER BY t.name) AS tags
       FROM projects p
       LEFT JOIN project_tags pt ON pt.project_id = p.id
       LEFT JOIN tags t ON t.id = pt.tag_id
       LEFT JOIN attachments a_cover ON a_cover.id = p.cover_attachment_id
       GROUP BY p.id, p.slug, p.parent_id, p.name, p.domain, p.status,
                p.tagline, p.visibility, p.repo, p.source_url, p.description,
                a_cover.file_path"""
  depSql = "SELECT blocker_id, blocked_id, dependency_type FROM dependency_graph"
