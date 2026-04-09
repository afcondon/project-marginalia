-- | Agent-optimized API endpoints
-- |
-- | Compact, structured responses designed for LLM/agent consumption.
-- | Key differences from the human API:
-- |   - IDs are prominent (agents reference by ID)
-- |   - statusOptions per project (lifecycle graph encoded in PureScript)
-- |   - Descriptions truncated to 200 chars in list views
-- |   - Flat response shapes, no superfluous wrapper objects
module API.Agent
  ( agentListProjects
  , agentGetProject
  , agentUpdateStatus
  , agentAddNote
  , agentAddAttachment
  , agentSearch
  ) where

import Prelude

import Data.Argonaut.Core (Json)
import Data.Argonaut.Core (toObject, toString) as J
import Data.Argonaut.Parser (jsonParser)
import Data.Array as Array
import Data.Either (Either(..))
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Tuple (Tuple(..))
import Database.DuckDB (Database, Rows, queryAllParams, run, firstRow)
import Effect.Aff (Aff)
import Foreign (Foreign, unsafeToForeign)
import Foreign.Object as FO
import HTTPurple (Response, ok', badRequest', notFound)
import HTTPurple.Headers (ResponseHeaders, headers)

-- =============================================================================
-- Shared headers
-- =============================================================================

jsonHeaders :: ResponseHeaders
jsonHeaders = headers
  { "Content-Type": "application/json"
  , "Access-Control-Allow-Origin": "*"
  }

-- =============================================================================
-- FFI Imports
-- =============================================================================

foreign import buildAgentProjectListJson :: Rows -> FO.Object (Array String) -> String
foreign import buildAgentProjectDetailJson :: Foreign -> Rows -> Rows -> Rows -> Rows -> Array String -> String
foreign import buildAgentProjectSummaryJson :: Foreign -> Array String -> String
foreign import buildAgentNoteJson :: Foreign -> String
foreign import buildAgentAttachmentJson :: Foreign -> String
foreign import buildAgentSearchJson :: String -> Rows -> Rows -> String
foreign import extractRowStatus :: Foreign -> String

-- =============================================================================
-- Status lifecycle graph
-- =============================================================================

-- | Valid next statuses for each current status. Must match the frontend's
-- | nextStatuses in Types.purs — both enforce the same lifecycle DAG, but
-- | the server is authoritative (the agent status endpoint validates here
-- | before any DB write). Dormant is the "paused indefinitely" state
-- | reachable from active/blocked; see the longer comment in Types.purs.
statusOptions :: String -> Array String
statusOptions s = case s of
  "idea"    -> [ "someday", "active", "defunct" ]
  "someday" -> [ "active", "idea", "defunct" ]
  "active"  -> [ "done", "dormant", "blocked", "defunct", "evolved" ]
  "dormant" -> [ "active", "defunct" ]
  "blocked" -> [ "active", "dormant", "defunct" ]
  "done"    -> [ "active" ]
  "defunct" -> [ "idea", "someday" ]
  "evolved" -> []
  _         -> []

-- | Check whether a status transition is valid.
isValidTransition :: String -> String -> Boolean
isValidTransition from to = Array.elem to (statusOptions from)

-- | Prebuilt map of all valid status options, passed to FFI for list responses.
allStatusOptions :: FO.Object (Array String)
allStatusOptions = FO.fromFoldable
  [ Tuple "idea"    (statusOptions "idea")
  , Tuple "someday" (statusOptions "someday")
  , Tuple "active"  (statusOptions "active")
  , Tuple "dormant" (statusOptions "dormant")
  , Tuple "blocked" (statusOptions "blocked")
  , Tuple "done"    (statusOptions "done")
  , Tuple "defunct" (statusOptions "defunct")
  , Tuple "evolved" (statusOptions "evolved")
  ]

-- =============================================================================
-- Body parsing helpers
-- =============================================================================

getField :: String -> FO.Object Json -> String
getField key obj = case FO.lookup key obj of
  Nothing   -> ""
  Just json -> fromMaybe "" (J.toString json)

getFieldMaybe :: String -> FO.Object Json -> Maybe String
getFieldMaybe key obj = case FO.lookup key obj of
  Nothing   -> Nothing
  Just json -> case J.toString json of
    Nothing -> Nothing
    Just "" -> Nothing
    Just s  -> Just s

parseBody :: String -> Maybe (FO.Object Json)
parseBody str = case jsonParser str of
  Left _     -> Nothing
  Right json -> J.toObject json

-- =============================================================================
-- GET /api/agent/projects
-- =============================================================================

-- | List projects in compact agent-optimized format.
-- | Supports ?domain=, ?status=, ?q= query parameters.
agentListProjects
  :: Database
  -> Maybe String   -- domain filter
  -> Maybe String   -- status filter
  -> Maybe String   -- full-text search
  -> Aff Response
agentListProjects db mDomain mStatus mQ = do
  let domainClause = case mDomain of
        Just _  -> " AND domain = ?"
        Nothing -> ""
  let statusClause = case mStatus of
        Just _  -> " AND status = ?"
        Nothing -> ""
  let searchClause = case mQ of
        Just _  -> " AND (LOWER(name) LIKE '%' || LOWER(?) || '%' OR LOWER(description) LIKE '%' || LOWER(?) || '%')"
        Nothing -> ""
  let sql = "SELECT * FROM projects WHERE 1=1"
        <> domainClause
        <> statusClause
        <> searchClause
        <> " ORDER BY domain, subdomain, name"
  let params = buildListParams mDomain mStatus mQ
  rows <- queryAllParams db sql params
  ok' jsonHeaders (buildAgentProjectListJson rows allStatusOptions)

buildListParams :: Maybe String -> Maybe String -> Maybe String -> Array Foreign
buildListParams mDomain mStatus mQ =
  domainP <> statusP <> searchP
  where
  domainP = case mDomain of
    Just d  -> [ unsafeToForeign d ]
    Nothing -> []
  statusP = case mStatus of
    Just s  -> [ unsafeToForeign s ]
    Nothing -> []
  searchP = case mQ of
    Just q  -> [ unsafeToForeign q, unsafeToForeign q ]
    Nothing -> []

-- =============================================================================
-- GET /api/agent/projects/:id
-- =============================================================================

-- | Get full project detail in agent-friendly flat format.
-- | Includes tags, 3 most recent notes, dependencies, and 5 most recent
-- | status history entries.
agentGetProject :: Database -> Int -> Aff Response
agentGetProject db projectId = do
  let idParam = [ unsafeToForeign projectId ]

  projectRows <- queryAllParams db
    """SELECT p.*,
              (SELECT COUNT(*) FROM project_notes WHERE project_id = p.id) AS note_count
       FROM projects p
       WHERE p.id = ?"""
    idParam
  case firstRow projectRows of
    Nothing      -> notFound
    Just project -> do
      tagRows <- queryAllParams db
        """SELECT t.name
           FROM tags t
           JOIN project_tags pt ON pt.tag_id = t.id
           WHERE pt.project_id = ?
           ORDER BY t.name"""
        idParam

      noteRows <- queryAllParams db
        """SELECT content, author,
                  strftime(created_at, '%Y-%m-%d') AS date
           FROM project_notes
           WHERE project_id = ?
           ORDER BY created_at DESC
           LIMIT 3"""
        idParam

      depRows <- queryAllParams db
        """SELECT d.blocker_id, b1.name AS blocker_name,
                  d.blocked_id, b2.name AS blocked_name
           FROM dependencies d
           JOIN projects b1 ON d.blocker_id = b1.id
           JOIN projects b2 ON d.blocked_id = b2.id
           WHERE d.blocker_id = ? OR d.blocked_id = ?"""
        [ unsafeToForeign projectId, unsafeToForeign projectId ]

      histRows <- queryAllParams db
        """SELECT old_status, new_status,
                  strftime(changed_at, '%Y-%m-%d') AS date,
                  COALESCE(reason, '') AS reason
           FROM status_history
           WHERE project_id = ?
           ORDER BY changed_at DESC
           LIMIT 5"""
        idParam

      let options = statusOptions (extractRowStatus project)
      ok' jsonHeaders
        (buildAgentProjectDetailJson project tagRows noteRows depRows histRows options)

-- =============================================================================
-- POST /api/agent/projects/:id/status
-- =============================================================================

-- | Update project status with lifecycle validation.
-- | Returns 400 with a descriptive error if the transition is invalid.
agentUpdateStatus :: Database -> Int -> String -> Aff Response
agentUpdateStatus db projectId bodyStr = case parseBody bodyStr of
  Nothing  -> badRequest' jsonHeaders """{"error": "Invalid JSON body"}"""
  Just obj -> do
    let newStatus = getField "status" obj
    let reason = fromMaybe "Updated via agent API" (getFieldMaybe "reason" obj)
    let author = fromMaybe "agent" (getFieldMaybe "author" obj)

    -- Fetch current project
    let idParam = [ unsafeToForeign projectId ]
    projectRows <- queryAllParams db
      "SELECT * FROM projects WHERE id = ?"
      idParam
    case firstRow projectRows of
      Nothing      -> notFound
      Just project -> do
        let currentStatus = extractRowStatus project
        if isValidTransition currentStatus newStatus
          then do
            -- Update status and timestamp
            run db
              "UPDATE projects SET status = ?, updated_at = current_timestamp WHERE id = ?"
              [ unsafeToForeign newStatus, unsafeToForeign projectId ]

            -- Record in history
            run db
              "INSERT INTO status_history (project_id, old_status, new_status, reason, author) VALUES (?, ?, ?, ?, ?)"
              [ unsafeToForeign projectId
              , unsafeToForeign currentStatus
              , unsafeToForeign newStatus
              , unsafeToForeign reason
              , unsafeToForeign author
              ]

            -- Return updated project
            updatedRows <- queryAllParams db
              "SELECT * FROM projects WHERE id = ?"
              idParam
            case firstRow updatedRows of
              Nothing      -> notFound
              Just updated ->
                ok' jsonHeaders
                  (buildAgentProjectSummaryJson updated (statusOptions newStatus))
          else do
            let validOpts = statusOptions currentStatus
            let optsList = "['" <> joinWith "', '" validOpts <> "']"
            badRequest' jsonHeaders
              ( "{\"error\": \"Cannot transition from '"
              <> currentStatus
              <> "' to '"
              <> newStatus
              <> "'. Valid options: "
              <> optsList
              <> "\"}"
              )

-- =============================================================================
-- POST /api/agent/projects/:id/notes
-- =============================================================================

-- | Add a note to a project.
-- | author defaults to "agent" if not provided.
agentAddNote :: Database -> Int -> String -> Aff Response
agentAddNote db projectId bodyStr = case parseBody bodyStr of
  Nothing  -> badRequest' jsonHeaders """{"error": "Invalid JSON body"}"""
  Just obj -> do
    let content = getField "content" obj
    let author = fromMaybe "agent" (getFieldMaybe "author" obj)

    -- Verify project exists
    let idParam = [ unsafeToForeign projectId ]
    projectRows <- queryAllParams db
      "SELECT id FROM projects WHERE id = ?"
      idParam
    case firstRow projectRows of
      Nothing -> notFound
      Just _  -> do
        run db
          "INSERT INTO project_notes (project_id, content, author) VALUES (?, ?, ?)"
          [ unsafeToForeign projectId
          , unsafeToForeign content
          , unsafeToForeign author
          ]

        -- Fetch the inserted note
        noteRows <- queryAllParams db
          "SELECT * FROM project_notes WHERE project_id = ? ORDER BY created_at DESC LIMIT 1"
          idParam
        case firstRow noteRows of
          Nothing   -> ok' jsonHeaders "{}"
          Just note -> ok' jsonHeaders (buildAgentNoteJson note)

-- =============================================================================
-- POST /api/agent/projects/:id/attachments
-- =============================================================================

-- | Register an attachment reference on a project.
-- |
-- | This is a "reference" attachment, not a content upload: the caller passes
-- | a filesystem path that already exists and we record it in the attachments
-- | table. Useful for linking Claude-generated artifacts (reports, indexes,
-- | plans) to the project they belong to without having to stuff their bytes
-- | into DuckDB.
-- |
-- | Body shape:
-- |   { "filename":    "remastering-inventory.md"   (required)
-- |   , "filePath":    "/abs/path/to/file"          (required)
-- |   , "mimeType":    "text/markdown"              (optional, default application/octet-stream)
-- |   , "description": "..."                        (optional)
-- |   }
-- |
-- | Returns the newly inserted attachment row in agent-friendly format,
-- | including a /attachments/... url if the file lives inside the canonical
-- | attachment store at /Volumes/Crucial4TB/Documents/Notes Attachments/.
agentAddAttachment :: Database -> Int -> String -> Aff Response
agentAddAttachment db projectId bodyStr = case parseBody bodyStr of
  Nothing  -> badRequest' jsonHeaders """{"error": "Invalid JSON body"}"""
  Just obj -> do
    let filename = getField "filename" obj
    let filePath = getField "filePath" obj
    let mimeType = fromMaybe "application/octet-stream" (getFieldMaybe "mimeType" obj)
    let description = getField "description" obj

    if filename == "" || filePath == ""
      then badRequest' jsonHeaders
        """{"error": "filename and filePath are required"}"""
      else do
        -- Verify project exists
        let idParam = [ unsafeToForeign projectId ]
        projectRows <- queryAllParams db
          "SELECT id FROM projects WHERE id = ?"
          idParam
        case firstRow projectRows of
          Nothing -> notFound
          Just _  -> do
            run db
              "INSERT INTO attachments (project_id, filename, mime_type, file_path, description) VALUES (?, ?, ?, ?, ?)"
              [ unsafeToForeign projectId
              , unsafeToForeign filename
              , unsafeToForeign mimeType
              , unsafeToForeign filePath
              , unsafeToForeign description
              ]

            -- Fetch the inserted row
            attRows <- queryAllParams db
              "SELECT * FROM attachments WHERE project_id = ? ORDER BY created_at DESC, id DESC LIMIT 1"
              idParam
            case firstRow attRows of
              Nothing  -> ok' jsonHeaders "{}"
              Just att -> ok' jsonHeaders (buildAgentAttachmentJson att)

-- =============================================================================
-- GET /api/agent/search
-- =============================================================================

-- | Fast text search across project names and descriptions.
-- | Returns deduplicated results with a match indicator (name | description).
agentSearch :: Database -> String -> Aff Response
agentSearch db q = do
  let likeParam = unsafeToForeign q
  nameRows <- queryAllParams db
    "SELECT id, name, domain, status FROM projects WHERE LOWER(name) LIKE '%' || LOWER(?) || '%' ORDER BY name"
    [ likeParam ]
  descRows <- queryAllParams db
    "SELECT id, name, domain, status FROM projects WHERE LOWER(description) LIKE '%' || LOWER(?) || '%' ORDER BY name"
    [ likeParam ]
  ok' jsonHeaders (buildAgentSearchJson q nameRows descRows)

-- =============================================================================
-- Internal helpers
-- =============================================================================

joinWith :: String -> Array String -> String
joinWith sep arr = Array.intercalate sep arr
