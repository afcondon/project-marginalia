module ProjectTracker.Server.Main where

import Prelude

import API.Agent as Agent
import API.Dependencies as Dependencies
import API.Projects as Projects
import API.Servers as Servers
import API.Stats as Stats
import Data.Generic.Rep (class Generic)
import Database.DuckDB as DB
import Effect (Effect)
import Effect.Aff (launchAff_)
import Effect.Class (liftEffect)
import Effect.Console (log)
import Effect.Ref as Ref
import Foreign.Object as Object
import Data.Maybe (fromMaybe)
import HTTPurple (Method(..), serve, ok, ok', toString)
import HTTPurple.Headers (headers)
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
  | AgentSearch
  | Dependencies
  | DependencyById Int Int

derive instance Generic Route _

route :: RouteDuplex' Route
route = root $ sum
  { "Projects": path "api/projects" noArgs
  , "ProjectById": path "api/projects" (int segment)
  , "ProjectTags": path "api/projects" (suffix (int segment) "tags")
  , "ProjectRename": path "api/projects" (suffix (int segment) "rename")
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
  , "AgentSearch": path "api/agent/search" noArgs
  , "Dependencies": path "api/dependencies" noArgs
  , "DependencyById": path "api/dependencies" (int segment `product` int segment)
  }

-- =============================================================================
-- Server
-- =============================================================================

dbPath :: String
dbPath = "./database/tracker.duckdb"

main :: Effect Unit
main = launchAff_ do
  db <- DB.openDB dbPath
  dbRef <- liftEffect $ Ref.new db
  liftEffect $ log $ "Connected to database: " <> dbPath

  liftEffect do
    _ <- serve { port: 3100 } { route, router: mkRouter dbRef }
    log "Project Tracker API server running on http://localhost:3100"
    log ""
    log "Endpoints:"
    log "  GET    /api/projects                     - List projects (filterable)"
    log "  GET    /api/projects/:id                 - Get project with details"
    log "  POST   /api/projects                     - Create a project"
    log "  PUT    /api/projects/:id                 - Update a project"
    log "  GET    /api/stats                        - Domain/status statistics"
    log ""
    log "Agent endpoints:"
    log "  GET    /api/agent/projects               - Compact project list"
    log "  GET    /api/agent/projects/:id           - Full project detail"
    log "  POST   /api/agent/projects/:id/status      - Update status (validated)"
    log "  POST   /api/agent/projects/:id/notes       - Add a note"
    log "  POST   /api/agent/projects/:id/attachments - Register an attachment reference"
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
  mkRouter dbRef { route: r, query, method, body } = do
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
