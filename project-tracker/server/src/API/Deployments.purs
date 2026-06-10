-- | Deployments registry — read HTTP endpoints (Phase 2A).
-- |
-- | Deployments are published builds reachable via a stable URL (Cloudflare
-- | Pages, GitHub Pages, etc.). Distinct from project_servers: servers are
-- | long-running processes on a port; deployments are artifacts at a URL.
-- |
-- | Phase 2A exposes read endpoints only so the SDI deploy runner can look
-- | up a deployment's commands without stopping marginalia for direct SQL.
-- | POST/PUT/DELETE and a /run endpoint are Phase 2B.
module API.Deployments
  ( listDeployments
  , getDeployment
  ) where

import Prelude

import Control.Monad.Except (runExcept)
import Data.Argonaut.Core (Json)
import Data.Argonaut.Core as J
import Data.Array (catMaybes, uncons) as Array
import Data.Either (Either(..))
import Data.Int (toNumber) as Int
import Data.Maybe (Maybe(..), maybe)
import Data.Tuple.Nested ((/\))
import Database.DuckDB (Database, queryAll, queryAllParams)
import Effect.Aff (Aff)
import Foreign (F, Foreign, readInt, readNullOrUndefined, readString, unsafeToForeign)
import Foreign.Index (readProp)
import Foreign.Object (fromFoldable) as Object
import HTTPurple (Response, ok', notFound)
import HTTPurple.Headers (ResponseHeaders, headers)
import Data.Traversable (traverse)

-- =============================================================================
-- Headers
-- =============================================================================

jsonHeaders :: ResponseHeaders
jsonHeaders = headers
  { "Content-Type": "application/json"
  , "Access-Control-Allow-Origin": "*"
  }

-- =============================================================================
-- Row type + decoder
-- =============================================================================

type DeploymentRow =
  { id :: Int
  , projectId :: Int
  , projectName :: String
  , platform :: String
  , url :: String
  , targetName :: Maybe String
  , sourcePath :: Maybe String
  , buildCommand :: Maybe String
  , deployCommand :: Maybe String
  , lastDeployedAt :: Maybe String
  , lastDeployStatus :: Maybe String
  , description :: Maybe String
  }

decodeDeploymentRow :: Foreign -> F DeploymentRow
decodeDeploymentRow f = do
  id <- readProp "id" f >>= readInt
  projectId <- readProp "project_id" f >>= readInt
  projectName <- readProp "project_name" f >>= readString
  platform <- readProp "platform" f >>= readString
  url <- readProp "url" f >>= readString
  targetName <- readProp "target_name" f >>= readNullOrUndefined >>= traverse readString
  sourcePath <- readProp "source_path" f >>= readNullOrUndefined >>= traverse readString
  buildCommand <- readProp "build_command" f >>= readNullOrUndefined >>= traverse readString
  deployCommand <- readProp "deploy_command" f >>= readNullOrUndefined >>= traverse readString
  lastDeployedAt <- readProp "last_deployed_at" f >>= readNullOrUndefined >>= traverse readString
  lastDeployStatus <- readProp "last_deploy_status" f >>= readNullOrUndefined >>= traverse readString
  description <- readProp "description" f >>= readNullOrUndefined >>= traverse readString
  pure
    { id, projectId, projectName, platform, url, targetName, sourcePath
    , buildCommand, deployCommand, lastDeployedAt, lastDeployStatus, description
    }

decodeDeploymentRows :: Array Foreign -> Array DeploymentRow
decodeDeploymentRows = Array.catMaybes <<< map attempt
  where
  attempt :: Foreign -> Maybe DeploymentRow
  attempt f = case runExcept (decodeDeploymentRow f) of
    Left _ -> Nothing
    Right r -> Just r

-- =============================================================================
-- Encoder
-- =============================================================================

encodeDeploymentRow :: DeploymentRow -> Json
encodeDeploymentRow r = J.fromObject $ Object.fromFoldable
  [ "id" /\ J.fromNumber (Int.toNumber r.id)
  , "projectId" /\ J.fromNumber (Int.toNumber r.projectId)
  , "projectName" /\ J.fromString r.projectName
  , "platform" /\ J.fromString r.platform
  , "url" /\ J.fromString r.url
  , "targetName" /\ maybeString r.targetName
  , "sourcePath" /\ maybeString r.sourcePath
  , "buildCommand" /\ maybeString r.buildCommand
  , "deployCommand" /\ maybeString r.deployCommand
  , "lastDeployedAt" /\ maybeString r.lastDeployedAt
  , "lastDeployStatus" /\ maybeString r.lastDeployStatus
  , "description" /\ maybeString r.description
  ]
  where
  maybeString = maybe J.jsonNull J.fromString

encodeDeploymentsEnvelope :: Array DeploymentRow -> String
encodeDeploymentsEnvelope rows =
  let envelope = J.fromObject $ Object.fromFoldable
        [ "deployments" /\ J.fromArray (map encodeDeploymentRow rows)
        , "count" /\ J.fromNumber (Int.toNumber (countOf rows))
        ]
  in J.stringify envelope
  where
  countOf :: Array DeploymentRow -> Int
  countOf = foldCount 0
  foldCount n xs = case Array.uncons xs of
    Nothing -> n
    Just { tail } -> foldCount (n + 1) tail

-- =============================================================================
-- GET /api/deployments
-- =============================================================================

listDeployments :: Database -> Aff Response
listDeployments db = do
  rows <- queryAll db
    """SELECT d.id, d.project_id, p.name AS project_name,
              d.platform, d.url, d.target_name, d.source_path,
              d.build_command, d.deploy_command,
              CAST(d.last_deployed_at AS TEXT) AS last_deployed_at,
              d.last_deploy_status, d.description
       FROM deployments d
       JOIN projects p ON p.id = d.project_id
       ORDER BY d.id"""
  let decoded = decodeDeploymentRows rows
  ok' jsonHeaders (encodeDeploymentsEnvelope decoded)

-- =============================================================================
-- GET /api/deployments/:id
-- =============================================================================

getDeployment :: Database -> Int -> Aff Response
getDeployment db deploymentId = do
  rows <- queryAllParams db
    """SELECT d.id, d.project_id, p.name AS project_name,
              d.platform, d.url, d.target_name, d.source_path,
              d.build_command, d.deploy_command,
              CAST(d.last_deployed_at AS TEXT) AS last_deployed_at,
              d.last_deploy_status, d.description
       FROM deployments d
       JOIN projects p ON p.id = d.project_id
       WHERE d.id = ?"""
    [ unsafeToForeign deploymentId ]
  case Array.uncons (decodeDeploymentRows rows) of
    Nothing -> notFound
    Just { head } -> ok' jsonHeaders (J.stringify (encodeDeploymentRow head))
