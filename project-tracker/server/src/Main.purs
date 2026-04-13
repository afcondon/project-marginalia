module ProjectTracker.Server.Main where

import Prelude

import API.Agent as Agent
import API.Dependencies as Dependencies
import API.Exercise as Exercise
import API.Projects as Projects
import API.Servers as Servers
import API.Stats as Stats
import API.Subscriptions as Subscriptions
import BlogDrafts as BlogDrafts
import Control.Monad.Error.Class (try)
import Data.Either (Either(..))
import Data.Generic.Rep (class Generic)
import Database.DuckDB as DB
import Effect (Effect)
import Effect.Aff (launchAff_)
import Effect.Class (liftEffect)
import Effect.Console (log)
import Effect.Exception (message)
import Effect.Ref as Ref
import Foreign.Object as Object
import Data.Maybe (fromMaybe)
import HTTPurple (Method(..), serve, ok, ok', toBuffer, toString)
import HTTPurple.Headers (headers)
import HTTPurple.Lookup ((!!))

import Node.Encoding (Encoding(..))
import Node.FS.Sync (readTextFile)
import Routing.Duplex (RouteDuplex', root, path, int, segment, suffix)
import Routing.Duplex.Generic (noArgs, product, sum)

-- =============================================================================
-- Routes
-- =============================================================================

data Route
  = Projects
  | ProjectById Int
  | ProjectTags Int
  | ProjectRename Int
  | ProjectBlogOpen Int
  | ProjectServers Int
  | Ports
  | PortsSuggest
  | ServerById Int
  | Stats
  | AgentProjects
  | AgentProjectById Int
  | AgentProjectStatus Int
  | AgentProjectNote Int
  | AgentProjectAttachment Int
  | AgentProjectAttachmentUpload Int
  | AgentSearch
  | Dependencies
  | DependencyById Int Int
  -- Finance section
  | Subscriptions
  | SubscriptionById Int
  | SubscriptionsUpcoming
  -- Letters section (blog drafts)
  | BlogDrafts
  | BlogAssets Int
  -- Sports section
  | ExerciseLog
  | ExerciseSummary

derive instance Generic Route _

route :: RouteDuplex' Route
route = root $ sum
  { "Projects": path "api/projects" noArgs
  , "ProjectById": path "api/projects" (int segment)
  , "ProjectTags": path "api/projects" (suffix (int segment) "tags")
  , "ProjectRename": path "api/projects" (suffix (int segment) "rename")
  , "ProjectBlogOpen": path "api/projects" (suffix (suffix (int segment) "blog") "open")
  , "ProjectServers": path "api/projects" (suffix (int segment) "servers")
  , "Ports": path "api/ports" noArgs
  , "PortsSuggest": path "api/ports/suggest" noArgs
  , "ServerById": path "api/servers" (int segment)
  , "Stats": path "api/stats" noArgs
  , "AgentProjects": path "api/agent/projects" noArgs
  , "AgentProjectById": path "api/agent/projects" (int segment)
  , "AgentProjectStatus": path "api/agent/projects" (suffix (int segment) "status")
  , "AgentProjectNote": path "api/agent/projects" (suffix (int segment) "notes")
  , "AgentProjectAttachment": path "api/agent/projects" (suffix (int segment) "attachments")
  , "AgentProjectAttachmentUpload": path "api/agent/projects" (suffix (suffix (int segment) "attachments") "upload")
  , "AgentSearch": path "api/agent/search" noArgs
  , "BlogDrafts": path "api/blog/drafts" noArgs
  , "BlogAssets": path "api/projects" (suffix (suffix (int segment) "blog") "assets")
  , "Subscriptions": path "api/subscriptions" noArgs
  , "SubscriptionById": path "api/subscriptions" (int segment)
  , "SubscriptionsUpcoming": path "api/subscriptions/upcoming" noArgs
  , "ExerciseLog": path "api/exercise" noArgs
  , "ExerciseSummary": path "api/exercise/summary" noArgs
  , "Dependencies": path "api/dependencies" noArgs
  , "DependencyById": path "api/dependencies" (int segment `product` int segment)
  }

-- =============================================================================
-- Server
-- =============================================================================

dbPath :: String
dbPath = "./database/tracker.duckdb"

schemaPath :: String
schemaPath = "./database/schema.sql"

main :: Effect Unit
main = launchAff_ do
  db <- DB.openDB dbPath
  dbRef <- liftEffect $ Ref.new db
  liftEffect $ log $ "Connected to database: " <> dbPath

  -- Apply the full schema from database/schema.sql on every startup. It's
  -- built entirely out of CREATE TABLE IF NOT EXISTS / CREATE VIEW IF NOT
  -- EXISTS / CREATE INDEX IF NOT EXISTS statements plus idempotent ALTERs,
  -- so re-running it on an existing DB is a no-op. This means a fresh
  -- clone on a new machine just needs to start the server — no separate
  -- migrate step — and new tables added to schema.sql land automatically.
  mSchemaSrc <- liftEffect $ try $ readTextFile UTF8 schemaPath
  case mSchemaSrc of
    Left err -> liftEffect $ log $
      "Warning: could not read " <> schemaPath <> ": " <> message err
        <> " (server will rely on pre-existing schema)"
    Right sql -> do
      DB.exec db sql
      liftEffect $ log "Schema applied from schema.sql"

  -- Idempotent column adds at boot for schemas created before a column
  -- existed. These are also present in schema.sql so they're belt-and-
  -- braces when the file-read succeeds; they still work standalone if the
  -- schema.sql read fails above. DuckDB supports ADD COLUMN IF NOT EXISTS.
  DB.exec db "ALTER TABLE projects ADD COLUMN IF NOT EXISTS cover_attachment_id INTEGER"
  DB.exec db "ALTER TABLE projects ADD COLUMN IF NOT EXISTS blog_status TEXT"
  DB.exec db "ALTER TABLE projects ADD COLUMN IF NOT EXISTS blog_content TEXT"
  liftEffect $ log "Schema migrations applied"

  -- One-time hoist of existing DB blog_content values into <slug>.md
  -- files on disk. Idempotent: after the first successful pass the
  -- blog_content column is NULLed for every migrated row, so subsequent
  -- boots find zero rows to process.
  summary <- BlogDrafts.migrateLegacyDrafts db
  liftEffect $ log $ "Blog drafts migration: "
    <> show summary.written <> " written, "
    <> show summary.skipped <> " skipped, "
    <> show summary.errored <> " errored"

  liftEffect do
    _ <- serve { port: 3100 } { route, router: mkRouter dbRef }
    log "Project Tracker API server running on http://localhost:3100"
    log ""
    log "Endpoints:"
    log "  GET    /api/projects                     - List projects (filterable)"
    log "  GET    /api/projects/:id                 - Get project with details"
    log "  POST   /api/projects                     - Create a project"
    log "  PUT    /api/projects/:id                 - Update a project"
    log "  POST   /api/projects/:id/blog/open         - Open blog draft in VS Code"
    log "  GET    /api/stats                        - Domain/status statistics"
    log ""
    log "Agent endpoints:"
    log "  GET    /api/agent/projects               - Compact project list"
    log "  GET    /api/agent/projects/:id           - Full project detail"
    log "  POST   /api/agent/projects/:id/status      - Update status (validated)"
    log "  POST   /api/agent/projects/:id/notes       - Add a note"
    log "  POST   /api/agent/projects/:id/attachments - Register an attachment reference"
    log "  POST   /api/agent/projects/:id/attachments/upload - Upload a file"
    log "  GET    /api/agent/search?q=...             - Text search"
    log ""
    log "Dependency endpoints:"
    log "  GET    /api/dependencies                 - List dependencies (filterable by ?type=)"
    log "  POST   /api/dependencies                 - Create a dependency"
    log "  DELETE /api/dependencies/:blocker/:blocked - Delete a dependency"
  where
  corsHeaders = headers
    { "Access-Control-Allow-Origin": "*"
    , "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS"
    , "Access-Control-Allow-Headers": "Content-Type"
    }
  mkRouter dbRef { route: r, query, method, body, headers: reqHeaders } = do
    db <- liftEffect $ Ref.read dbRef
    case r of
      Projects -> case method of
        Get -> do
          let mDomain = Object.lookup "domain" query
          let mStatus = Object.lookup "status" query
          let mTag = Object.lookup "tag" query
          let mAncestor = Object.lookup "ancestor" query
          let mSearch = Object.lookup "search" query
          Projects.listProjects db mDomain mStatus mTag mAncestor mSearch
        Post -> do
          bodyStr <- toString body
          Projects.createProject db bodyStr
        Options -> ok' corsHeaders ""
        _ -> ok """{ "error": "Method not allowed" }"""

      ProjectById projectId -> case method of
        Get -> Projects.getProject db projectId
        Put -> do
          bodyStr <- toString body
          Projects.updateProject db projectId bodyStr
        Options -> ok' corsHeaders ""
        _ -> ok """{ "error": "Method not allowed" }"""

      ProjectTags projectId -> case method of
        Post -> do
          bodyStr <- toString body
          Projects.addTag db projectId bodyStr
        Options -> ok' corsHeaders ""
        _ -> ok """{ "error": "Method not allowed" }"""

      ProjectRename projectId -> case method of
        Post -> do
          bodyStr <- toString body
          Projects.renameProject db projectId bodyStr
        Options -> ok' corsHeaders ""
        _ -> ok """{ "error": "Method not allowed" }"""

      ProjectBlogOpen projectId -> case method of
        Post -> Projects.openBlogDraft db projectId
        Options -> ok' corsHeaders ""
        _ -> ok """{ "error": "Method not allowed" }"""

      ProjectServers projectId -> case method of
        Get -> Servers.listServersForProject db projectId
        Post -> do
          bodyStr <- toString body
          Servers.addServer db projectId bodyStr
        Options -> ok' corsHeaders ""
        _ -> ok """{ "error": "Method not allowed" }"""

      Ports -> case method of
        Get -> Servers.listPorts db
        Options -> ok' corsHeaders ""
        _ -> ok """{ "error": "Method not allowed" }"""

      PortsSuggest -> case method of
        Get -> Servers.suggestPort db
        Options -> ok' corsHeaders ""
        _ -> ok """{ "error": "Method not allowed" }"""

      ServerById serverId -> case method of
        Delete -> Servers.deleteServer db serverId
        Options -> ok' corsHeaders ""
        _ -> ok """{ "error": "Method not allowed" }"""

      Stats -> case method of
        Get -> Stats.getStats db
        Options -> ok' corsHeaders ""
        _ -> ok """{ "error": "Method not allowed" }"""

      AgentProjects -> case method of
        Get -> do
          let mDomain = Object.lookup "domain" query
          let mStatus = Object.lookup "status" query
          let mQ = Object.lookup "q" query
          Agent.agentListProjects db mDomain mStatus mQ
        Options -> ok' corsHeaders ""
        _ -> ok """{ "error": "Method not allowed" }"""

      AgentProjectById projectId -> case method of
        Get -> Agent.agentGetProject db projectId
        Options -> ok' corsHeaders ""
        _ -> ok """{ "error": "Method not allowed" }"""

      AgentProjectStatus projectId -> case method of
        Post -> do
          bodyStr <- toString body
          Agent.agentUpdateStatus db projectId bodyStr
        Options -> ok' corsHeaders ""
        _ -> ok """{ "error": "Method not allowed" }"""

      AgentProjectNote projectId -> case method of
        Post -> do
          bodyStr <- toString body
          Agent.agentAddNote db projectId bodyStr
        Options -> ok' corsHeaders ""
        _ -> ok """{ "error": "Method not allowed" }"""

      AgentProjectAttachment projectId -> case method of
        Post -> do
          bodyStr <- toString body
          Agent.agentAddAttachment db projectId bodyStr
        Options -> ok' corsHeaders ""
        _ -> ok """{ "error": "Method not allowed" }"""

      AgentProjectAttachmentUpload projectId -> case method of
        Post -> do
          buf <- toBuffer body
          let contentType = fromMaybe "application/octet-stream" (reqHeaders !! "content-type")
          let description = fromMaybe "" (Object.lookup "description" query)
          Agent.agentUploadAttachment db projectId buf contentType description
        Options -> ok' corsHeaders ""
        _ -> ok """{ "error": "Method not allowed" }"""

      AgentSearch -> case method of
        Get -> do
          let q = fromMaybe "" (Object.lookup "q" query)
          Agent.agentSearch db q
        Options -> ok' corsHeaders ""
        _ -> ok """{ "error": "Method not allowed" }"""

      Dependencies -> case method of
        Get -> do
          let mType = Object.lookup "type" query
          Dependencies.listDependencies db mType
        Post -> do
          bodyStr <- toString body
          Dependencies.createDependency db bodyStr
        Options -> ok' corsHeaders ""
        _ -> ok """{ "error": "Method not allowed" }"""

      DependencyById blockerId blockedId -> case method of
        Delete -> Dependencies.deleteDependency db blockerId blockedId
        Options -> ok' corsHeaders ""
        _ -> ok """{ "error": "Method not allowed" }"""

      -- Letters section — blog drafts
      BlogDrafts -> case method of
        Get -> Projects.listBlogDrafts db
        Options -> ok' corsHeaders ""
        _ -> ok """{ "error": "Method not allowed" }"""

      BlogAssets projectId -> case method of
        Get -> Projects.listBlogAssets db projectId
        Post -> do
          bodyStr <- toString body
          Projects.saveBlogAsset db projectId bodyStr
        Options -> ok' corsHeaders ""
        _ -> ok """{ "error": "Method not allowed" }"""

      -- Finance section — subscriptions
      Subscriptions -> case method of
        Get -> do
          let mCategory = Object.lookup "category" query
          Subscriptions.listSubscriptions db mCategory
        Post -> do
          bodyStr <- toString body
          Subscriptions.createSubscription db bodyStr
        Options -> ok' corsHeaders ""
        _ -> ok """{ "error": "Method not allowed" }"""

      SubscriptionById subId -> case method of
        Get -> Subscriptions.getSubscription db subId
        Put -> do
          bodyStr <- toString body
          Subscriptions.updateSubscription db subId bodyStr
        Delete -> Subscriptions.deleteSubscription db subId
        Options -> ok' corsHeaders ""
        _ -> ok """{ "error": "Method not allowed" }"""

      SubscriptionsUpcoming -> case method of
        Get -> do
          let days = fromMaybe "7" (Object.lookup "days" query)
          Subscriptions.upcomingSubscriptions db days
        Options -> ok' corsHeaders ""
        _ -> ok """{ "error": "Method not allowed" }"""

      -- Sports section — exercise log
      ExerciseLog -> case method of
        Get -> do
          let mActivity = Object.lookup "activity" query
          Exercise.listExercise db mActivity
        Post -> do
          bodyStr <- toString body
          Exercise.createExercise db bodyStr
        Options -> ok' corsHeaders ""
        _ -> ok """{ "error": "Method not allowed" }"""

      ExerciseSummary -> case method of
        Get -> Exercise.monthlySummary db
        Options -> ok' corsHeaders ""
        _ -> ok """{ "error": "Method not allowed" }"""
