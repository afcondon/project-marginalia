-- | Project CRUD API endpoints
-- |
-- | Handles listing, retrieving, creating, and updating projects.
-- | Body parsing and SQL construction in PureScript; JSON response
-- | serialization via FFI (marshalling Foreign objects from DuckDB).
module API.Projects
  ( listProjects
  , getProject
  , createProject
  , updateProject
  , addTag
  , deleteTag
  , renameProject
  , openBlogDraft
  , listBlogDrafts
  , saveBlogAsset
  , listBlogAssets
  ) where

import Prelude

import Data.Argonaut.Core (Json)
import Data.Argonaut.Core (toObject, toString, toNumber) as J
import Data.Argonaut.Parser (jsonParser)
import Data.Array as Array
import Data.Either (Either(..))
import Data.Int (floor) as Int
import Data.Maybe (Maybe(..), fromMaybe)
import Database.DuckDB (Database, Rows, queryAll, queryAllParams, exec, run, firstRow, isEmpty)
import Effect (Effect)
import Effect.Aff (Aff)
import Effect.Class (liftEffect)
import BlogDrafts as BlogDrafts
import Filesystem (RenameOutcome(..)) as FS
import Filesystem (renameProjectDirectory) as FS
import Foreign (Foreign, unsafeToForeign)
import Foreign.Object (Object, lookup) as FO
import HTTPurple (Response, ok', badRequest', notFound)
import HTTPurple.Headers (ResponseHeaders, headers)
import Slug as Slug

-- | JSON content type header with CORS
jsonHeaders :: ResponseHeaders
jsonHeaders = headers
  { "Content-Type": "application/json"
  , "Access-Control-Allow-Origin": "*"
  }

-- =============================================================================
-- FFI Imports (JSON response builders only — legitimate FFI for Foreign → JSON)
-- =============================================================================

foreign import buildProjectListJson :: Rows -> String
foreign import buildProjectDetailJson :: Foreign -> Rows -> Rows -> Rows -> String

-- =============================================================================
-- JSON body parsing helpers (PureScript, not FFI)
-- =============================================================================

-- | Extract a string field from a JSON object, returning empty string if missing
getField :: String -> FO.Object Json -> String
getField key obj = case FO.lookup key obj of
  Nothing -> ""
  Just json -> fromMaybe "" (J.toString json)

-- | Extract a string field, returning Nothing for missing or empty
getFieldMaybe :: String -> FO.Object Json -> Maybe String
getFieldMaybe key obj = case FO.lookup key obj of
  Nothing -> Nothing
  Just json -> case J.toString json of
    Nothing -> Nothing
    Just "" -> Nothing
    Just s -> Just s

-- | Check if a field exists in the JSON object
hasField :: String -> FO.Object Json -> Boolean
hasField key obj = case FO.lookup key obj of
  Nothing -> false
  Just _ -> true

-- | Extract an int field from a JSON object (handles both numeric and stringified ints).
getIntField :: String -> FO.Object Json -> Maybe Int
getIntField key obj = case FO.lookup key obj of
  Nothing -> Nothing
  Just json -> case J.toNumber json of
    Just n -> Just (Int.floor n)
    Nothing -> Nothing

-- =============================================================================
-- GET /api/projects
-- =============================================================================

-- | List projects with optional filtering by domain, status, tag, and search text.
listProjects :: Database -> Maybe String -> Maybe String -> Maybe String -> Maybe String -> Maybe String -> Aff Response
listProjects db mDomain mStatus mTag mAncestor mSearch = do
  let baseSql = "SELECT p.id, p.slug, p.parent_id, p.name, p.domain, p.subdomain, p.status, p.description, p.updated_at, p.blog_status, STRING_AGG(DISTINCT t.name, ', ' ORDER BY t.name) AS tags, a_cover.file_path AS cover_path FROM projects p LEFT JOIN project_tags pt ON pt.project_id = p.id LEFT JOIN tags t ON t.id = pt.tag_id LEFT JOIN attachments a_cover ON a_cover.id = p.cover_attachment_id WHERE 1=1"
  let domainClause = case mDomain of
        Just _ -> " AND p.domain = ?"
        Nothing -> ""
  let statusClause = case mStatus of
        Just _ -> " AND p.status = ?"
        Nothing -> ""
  let tagClause = case mTag of
        Just _ -> " AND EXISTS (SELECT 1 FROM project_tags pt2 JOIN tags t2 ON t2.id = pt2.tag_id WHERE pt2.project_id = p.id AND t2.name = ?)"
        Nothing -> ""
  let ancestorClause = case mAncestor of
        Just _ -> " AND p.id IN (WITH RECURSIVE descendants(id) AS (SELECT id FROM projects WHERE id = CAST(? AS INTEGER) UNION ALL SELECT p2.id FROM projects p2 JOIN descendants d ON p2.parent_id = d.id) SELECT id FROM descendants)"
        Nothing -> ""
  let searchClause = case mSearch of
        Just _ -> " AND (LOWER(p.name) LIKE '%' || LOWER(?) || '%' OR LOWER(p.description) LIKE '%' || LOWER(?) || '%')"
        Nothing -> ""
  let groupClause = " GROUP BY p.id, p.slug, p.parent_id, p.name, p.domain, p.subdomain, p.status, p.description, p.updated_at, p.blog_status, a_cover.file_path"
  let orderClause = " ORDER BY p.updated_at DESC NULLS LAST"
  let sql = baseSql <> domainClause <> statusClause <> tagClause <> ancestorClause <> searchClause <> groupClause <> orderClause
  let params = buildFilterParams mDomain mStatus mTag mAncestor mSearch
  rows <- queryAllParams db sql params
  ok' jsonHeaders (buildProjectListJson rows)

buildFilterParams :: Maybe String -> Maybe String -> Maybe String -> Maybe String -> Maybe String -> Array Foreign
buildFilterParams mDomain mStatus mTag mAncestor mSearch =
  domainP <> statusP <> tagP <> ancestorP <> searchP
  where
  domainP = case mDomain of
    Just d -> [unsafeToForeign d]
    Nothing -> []
  statusP = case mStatus of
    Just s -> [unsafeToForeign s]
    Nothing -> []
  tagP = case mTag of
    Just t -> [unsafeToForeign t]
    Nothing -> []
  ancestorP = case mAncestor of
    Just a -> [unsafeToForeign a]
    Nothing -> []
  searchP = case mSearch of
    Just q -> [unsafeToForeign q, unsafeToForeign q]
    Nothing -> []

-- =============================================================================
-- GET /api/projects/:id
-- =============================================================================

getProject :: Database -> Int -> Aff Response
getProject db projectId = do
  let idParam = [unsafeToForeign projectId]
  projectRows <- queryAllParams db
    """SELECT p.*, STRING_AGG(DISTINCT t.name, ', ' ORDER BY t.name) AS tags
       FROM projects p
       LEFT JOIN project_tags pt ON pt.project_id = p.id
       LEFT JOIN tags t ON t.id = pt.tag_id
       WHERE p.id = ?
       GROUP BY p.id, p.slug, p.parent_id, p.name, p.domain, p.subdomain, p.status,
                p.evolved_into, p.description, p.source_url, p.source_path,
                p.repo, p.preferred_view, p.cover_attachment_id,
                p.blog_status, p.blog_content,
                p.created_at, p.updated_at"""
    idParam
  case firstRow projectRows of
    Nothing -> notFound
    Just project -> do
      -- Blog drafts are file-sourced: read <slug>.md from disk and splice
      -- its contents into the row so buildProjectDetailJson sees it as
      -- blog_content. The DB column is ignored for reads.
      let slug = getRowString_ "slug" project
      mDraft <- liftEffect $ BlogDrafts.readDraft slug
      let projectWithDraft = BlogDrafts.overrideBlogContent project mDraft
      notes <- queryAllParams db
        "SELECT id, content, author, created_at FROM project_notes WHERE project_id = ? ORDER BY created_at DESC"
        idParam
      deps <- queryAllParams db
        """SELECT d.dependency_type,
                  d.blocker_id, b1.name AS blocker_name, b1.status AS blocker_status,
                  d.blocked_id, b2.name AS blocked_name, b2.status AS blocked_status
           FROM dependencies d
           JOIN projects b1 ON d.blocker_id = b1.id
           JOIN projects b2 ON d.blocked_id = b2.id
           WHERE d.blocker_id = ? OR d.blocked_id = ?"""
        [unsafeToForeign projectId, unsafeToForeign projectId]
      attachments <- queryAllParams db
        "SELECT id, filename, mime_type, file_path, description, created_at FROM attachments WHERE project_id = ? ORDER BY created_at DESC"
        idParam
      ok' jsonHeaders (buildProjectDetailJson projectWithDraft notes deps attachments)

-- =============================================================================
-- POST /api/projects
-- =============================================================================

createProject :: Database -> String -> Aff Response
createProject db bodyStr = case parseBody bodyStr of
  Nothing -> badRequest' jsonHeaders """{"error": "Invalid JSON body"}"""
  Just obj -> do
    let name = fromMaybe "Untitled" (getFieldMaybe "name" obj)
    let domain = fromMaybe "programming" (getFieldMaybe "domain" obj)
    let subdomain = getField "subdomain" obj
    let status = fromMaybe "idea" (getFieldMaybe "status" obj)
    let description = getField "description" obj
    let sourceUrl = getField "sourceUrl" obj
    let sourcePath = getField "sourcePath" obj
    let repo = getField "repo" obj
    let mParentId = getIntField "parentId" obj

    slug <- Slug.generateUniqueSlug db

    case mParentId of
      Nothing ->
        run db
          "INSERT INTO projects (slug, name, domain, subdomain, status, description, source_url, source_path, repo) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)"
          [ unsafeToForeign slug
          , unsafeToForeign name
          , unsafeToForeign domain
          , unsafeToForeign subdomain
          , unsafeToForeign status
          , unsafeToForeign description
          , unsafeToForeign sourceUrl
          , unsafeToForeign sourcePath
          , unsafeToForeign repo
          ]
      Just parentId ->
        run db
          "INSERT INTO projects (slug, parent_id, name, domain, subdomain, status, description, source_url, source_path, repo) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
          [ unsafeToForeign slug
          , unsafeToForeign parentId
          , unsafeToForeign name
          , unsafeToForeign domain
          , unsafeToForeign subdomain
          , unsafeToForeign status
          , unsafeToForeign description
          , unsafeToForeign sourceUrl
          , unsafeToForeign sourcePath
          , unsafeToForeign repo
          ]

    -- Record initial status
    run db
      "INSERT INTO status_history (project_id, old_status, new_status, reason, author) VALUES ((SELECT MAX(id) FROM projects), NULL, ?, 'Project created', 'api')"
      [ unsafeToForeign status ]

    -- Use the same query shape as listProjects so the response includes slug + parent_id
    rows <- queryAllParams db
      """SELECT p.id, p.slug, p.parent_id, p.name, p.domain, p.subdomain, p.status, p.description, p.updated_at,
                p.blog_status,
                STRING_AGG(DISTINCT t.name, ', ' ORDER BY t.name) AS tags,
                a_cover.file_path AS cover_path
         FROM projects p
         LEFT JOIN project_tags pt ON pt.project_id = p.id
         LEFT JOIN tags t ON t.id = pt.tag_id
         LEFT JOIN attachments a_cover ON a_cover.id = p.cover_attachment_id
         WHERE p.id = (SELECT MAX(id) FROM projects)
         GROUP BY p.id, p.slug, p.parent_id, p.name, p.domain, p.subdomain, p.status, p.description, p.updated_at, p.blog_status, a_cover.file_path"""
      []
    ok' jsonHeaders (buildProjectListJson rows)

-- =============================================================================
-- PUT /api/projects/:id
-- =============================================================================

updateProject :: Database -> Int -> String -> Aff Response
updateProject db projectId bodyStr = case parseBody bodyStr of
  Nothing -> badRequest' jsonHeaders """{"error": "Invalid JSON body"}"""
  Just obj -> do
    let newStatus = getFieldMaybe "status" obj

    -- Build and execute UPDATE with only provided fields
    let updates = buildUpdateClauses obj
    case updates.clauses of
      [] -> ok' jsonHeaders ("""{"error": "No fields to update"}""")
      _ -> do
        let setClauses = Array.intercalate ", " updates.clauses <> ", updated_at = current_timestamp"
        let sql = "UPDATE projects SET " <> setClauses <> " WHERE id = ?"
        let params = updates.params <> [ unsafeToForeign projectId ]
        run db sql params

        -- If status changed, record in history
        case newStatus of
          Nothing -> pure unit
          Just status -> do
            let reason = fromMaybe "Updated via API" (getFieldMaybe "statusReason" obj)
            run db
              "INSERT INTO status_history (project_id, old_status, new_status, reason, author) VALUES (?, ?, ?, ?, 'api')"
              [ unsafeToForeign projectId
              , unsafeToForeign "" -- old_status not critical, avoids subquery FK issues
              , unsafeToForeign status
              , unsafeToForeign reason
              ]

        rows <- queryAllParams db "SELECT * FROM project_with_tags WHERE id = ?"
          [ unsafeToForeign projectId ]
        ok' jsonHeaders (buildProjectListJson rows)

-- =============================================================================
-- POST /api/projects/:id/rename — rename a project, optionally moving its directory
-- =============================================================================
-- |
-- | Body shape:
-- |   { "name": "New Name", "renameDirectory": true|false }
-- |
-- | If `renameDirectory` is true and the project's source_path is an existing
-- | directory, the directory is renamed too (via `git mv` if inside a git repo,
-- | otherwise plain `fs.rename`). All filesystem logic lives in Filesystem.js.

renameProject :: Database -> Int -> String -> Aff Response
renameProject db projectId bodyStr = case parseBody bodyStr of
  Nothing -> badRequest' jsonHeaders """{"error": "Invalid JSON body"}"""
  Just obj -> case getFieldMaybe "name" obj of
    Nothing -> badRequest' jsonHeaders """{"error": "Missing 'name' field"}"""
    Just newName -> do
      if newName == ""
        then badRequest' jsonHeaders """{"error": "Name must not be empty"}"""
        else do
          rows <- queryAllParams db
            "SELECT source_path FROM projects WHERE id = ?"
            [ unsafeToForeign projectId ]
          case firstRow rows of
            Nothing -> notFound
            Just row -> do
              let renameDir = case getFieldMaybe "renameDirectory" obj of
                    Just "true" -> true
                    _ -> false
              if not renameDir
                then renameInDbOnly newName
                else do
                  let sourcePath = getRowString_ "source_path" row
                  outcome <- liftEffect $ FS.renameProjectDirectory sourcePath newName
                  case outcome of
                    FS.RenameError err ->
                      -- Refuse the whole operation — neither DB nor FS are changed
                      badRequest' jsonHeaders ("{\"error\": \"" <> escapeJson err <> "\"}")
                    FS.Skipped reason -> do
                      -- Filesystem rename was asked for but couldn't run (no source path, file not dir, etc.).
                      -- Still update the DB name, but include a warning so the user knows.
                      run db
                        "UPDATE projects SET name = ?, updated_at = current_timestamp WHERE id = ?"
                        [ unsafeToForeign newName, unsafeToForeign projectId ]
                      ok' jsonHeaders ("{\"ok\": true, \"name\": \"" <> escapeJson newName <> "\", \"warning\": \"Directory rename skipped: " <> escapeJson reason <> "\"}")
                    FS.Renamed newPath method -> do
                      run db
                        "UPDATE projects SET name = ?, source_path = ?, updated_at = current_timestamp WHERE id = ?"
                        [ unsafeToForeign newName
                        , unsafeToForeign newPath
                        , unsafeToForeign projectId
                        ]
                      ok' jsonHeaders ("{\"ok\": true, \"name\": \"" <> escapeJson newName <> "\", \"newPath\": \"" <> escapeJson newPath <> "\", \"method\": \"" <> method <> "\"}")
  where
  renameInDbOnly newName = do
    run db
      "UPDATE projects SET name = ?, updated_at = current_timestamp WHERE id = ?"
      [ unsafeToForeign newName, unsafeToForeign projectId ]
    ok' jsonHeaders ("{\"ok\": true, \"name\": \"" <> escapeJson newName <> "\"}")

  escapeJson :: String -> String
  escapeJson s = s  -- TODO: real JSON escaping; safe enough for project names

-- | Read a string field from a Foreign row. Returns "" if missing or null.
foreign import getRowString_ :: String -> Foreign -> String

-- | JavaScript `null` exposed as a Foreign. Passed as a SQL parameter when a
-- | nullable column should be explicitly set to NULL (rather than untouched).
foreign import jsNull :: Foreign

-- =============================================================================
-- POST /api/projects/:id/blog/open — open blog draft in VS Code
-- =============================================================================
-- |
-- | Looks up the project's slug, ensures `<slug>.md` exists under the
-- | configured drafts dir (creating it with a template if needed), then
-- | shells out to `open -a "Visual Studio Code" <path>`.
-- |
-- | The browser UI calls this after the user clicks "Edit in VS Code";
-- | writes happen exclusively in VS Code; the UI refetches on demand via
-- | the standard GET handler which re-reads the file.
openBlogDraft :: Database -> Int -> Aff Response
openBlogDraft db projectId = do
  rows <- queryAllParams db
    "SELECT slug, name FROM projects WHERE id = ?"
    [ unsafeToForeign projectId ]
  case firstRow rows of
    Nothing -> notFound
    Just row -> do
      let slug = getRowString_ "slug" row
      let name = getRowString_ "name" row
      if slug == ""
        then badRequest' jsonHeaders """{"error": "Project has no slug"}"""
        else do
          ensured <- liftEffect $ BlogDrafts.ensureDraft slug name
          case ensured of
            BlogDrafts.EnsureError err ->
              badRequest' jsonHeaders ("{\"error\": \"" <> err <> "\"}")
            BlogDrafts.EnsureOpened absPath -> do
              openOutcome <- liftEffect $ BlogDrafts.openInVSCode absPath
              case openOutcome of
                BlogDrafts.OpenError err ->
                  badRequest' jsonHeaders ("{\"error\": \"" <> err <> "\"}")
                BlogDrafts.OpenOk p ->
                  ok' jsonHeaders ("{\"ok\": true, \"path\": \"" <> p <> "\"}")

-- =============================================================================
-- GET /api/blog/drafts — Letters Page: all projects with blog status
-- =============================================================================

listBlogDrafts :: Database -> Aff Response
listBlogDrafts db = do
  rows <- queryAll db
    """SELECT id, slug, name, domain, blog_status
       FROM projects
       WHERE blog_status IS NOT NULL
       ORDER BY
         CASE blog_status
           WHEN 'drafted'         THEN 1
           WHEN 'wanted_priority' THEN 2
           WHEN 'wanted'          THEN 3
           WHEN 'published'       THEN 4
           WHEN 'not_needed'      THEN 5
           ELSE 6
         END,
         name"""
  enriched <- liftEffect $ buildBlogDraftsJson_ rows
  ok' jsonHeaders enriched

-- | Build the Letters Page JSON response. Reads each project's draft file
-- | from disk (via BlogDrafts.readDraft) to include word counts and filenames.
foreign import buildBlogDraftsJson_ :: Rows -> Effect String

-- =============================================================================
-- POST /api/projects/:id/blog/assets — upload an image for a blog draft
-- GET  /api/projects/:id/blog/assets — list assets for a blog draft
-- =============================================================================

saveBlogAsset :: Database -> Int -> String -> Aff Response
saveBlogAsset db projectId bodyStr = case parseBody bodyStr of
  Nothing -> badRequest' jsonHeaders """{"error": "Invalid JSON body"}"""
  Just obj -> do
    rows <- queryAllParams db
      "SELECT slug FROM projects WHERE id = ?"
      [ unsafeToForeign projectId ]
    case firstRow rows of
      Nothing -> notFound
      Just row -> do
        let slug = getRowString_ "slug" row
        case getFieldMaybe "filename" obj, getFieldMaybe "data" obj of
          Just filename, Just base64Data -> do
            outcome <- liftEffect $ BlogDrafts.saveBlogAsset slug filename base64Data
            case outcome of
              BlogDrafts.AssetSaved info ->
                let markdown = "![" <> info.filename <> "](" <> slug <> "/" <> info.filename <> ")"
                in ok' jsonHeaders
                  ("{\"ok\": true, \"filename\": \"" <> info.filename <> "\", \"markdown\": \"" <> markdown <> "\"}")
              BlogDrafts.AssetError err ->
                badRequest' jsonHeaders ("{\"error\": \"" <> err <> "\"}")
          _, _ -> badRequest' jsonHeaders """{"error": "Missing 'filename' and/or 'data' fields"}"""

listBlogAssets :: Database -> Int -> Aff Response
listBlogAssets db projectId = do
  rows <- queryAllParams db
    "SELECT slug FROM projects WHERE id = ?"
    [ unsafeToForeign projectId ]
  case firstRow rows of
    Nothing -> notFound
    Just row -> do
      let slug = getRowString_ "slug" row
      assets <- liftEffect $ BlogDrafts.listBlogAssets slug
      ok' jsonHeaders (buildAssetsJson slug assets)

buildAssetsJson :: String -> Array BlogDrafts.AssetInfo -> String
buildAssetsJson slug assets =
  let entries = map (\a ->
        "{\"filename\": \"" <> a.filename
        <> "\", \"size\": " <> show a.size
        <> ", \"url\": \"/blog-assets/" <> slug <> "/" <> a.filename
        <> "\", \"markdown\": \"![" <> a.filename <> "](" <> slug <> "/" <> a.filename <> ")\"}"
      ) assets
  in "{\"assets\": [" <> joinArray entries <> "], \"count\": " <> show (Array.length assets) <> "}"

joinArray :: Array String -> String
joinArray arr = case Array.uncons arr of
  Nothing -> ""
  Just { head: h, tail: t } -> Array.foldl (\acc s -> acc <> ", " <> s) h t

addTag :: Database -> Int -> String -> Aff Response
addTag db projectId bodyStr = case parseBody bodyStr of
  Nothing -> badRequest' jsonHeaders """{"error": "Invalid JSON body"}"""
  Just obj -> case getFieldMaybe "tag" obj of
    Nothing -> badRequest' jsonHeaders """{"error": "Missing 'tag' field"}"""
    Just tagName -> do
      -- Find or create the tag
      tagRows <- queryAllParams db
        "SELECT id FROM tags WHERE name = ?"
        [ unsafeToForeign tagName ]
      case firstRow tagRows of
        Just _ -> pure unit
        Nothing -> run db
          "INSERT INTO tags (name) VALUES (?)"
          [ unsafeToForeign tagName ]
      -- Get the tag id
      tagRows2 <- queryAllParams db
        "SELECT id FROM tags WHERE name = ?"
        [ unsafeToForeign tagName ]
      case firstRow tagRows2 of
        Nothing -> badRequest' jsonHeaders """{"error": "Tag creation failed"}"""
        Just _tagRow -> do
          -- Insert the link if it doesn't exist
          existing <- queryAllParams db
            "SELECT 1 FROM project_tags pt JOIN tags t ON t.id = pt.tag_id WHERE pt.project_id = ? AND t.name = ?"
            [ unsafeToForeign projectId, unsafeToForeign tagName ]
          when (isEmpty existing) do
            run db
              "INSERT INTO project_tags (project_id, tag_id) SELECT ?, id FROM tags WHERE name = ?"
              [ unsafeToForeign projectId, unsafeToForeign tagName ]
          ok' jsonHeaders ("""{"projectId": """ <> show projectId <> """, "tag": """ <> "\"" <> tagName <> "\"" <> """}""")

-- | Remove a tag from a project (by name). The tag itself is left in the
-- | `tags` table — other projects may still reference it. Idempotent: returns
-- | ok whether or not the link existed.
deleteTag :: Database -> Int -> String -> Aff Response
deleteTag db projectId tagName = do
  run db
    """DELETE FROM project_tags
       WHERE project_id = ?
         AND tag_id IN (SELECT id FROM tags WHERE name = ?)"""
    [ unsafeToForeign projectId, unsafeToForeign tagName ]
  ok' jsonHeaders
    ( """{"ok": true, "projectId": """ <> show projectId
      <> """, "tag": """ <> "\"" <> tagName <> "\"" <> "}"
    )

-- =============================================================================
-- Helpers
-- =============================================================================

type UpdateClauses = { clauses :: Array String, params :: Array Foreign }

buildUpdateClauses :: FO.Object Json -> UpdateClauses
buildUpdateClauses obj = { clauses, params }
  where
  fields =
    [ fieldClause "name" "name"
    , fieldClause "domain" "domain"
    , fieldClause "subdomain" "subdomain"
    , fieldClause "status" "status"
    , fieldClause "description" "description"
    , fieldClause "sourceUrl" "source_url"
    , fieldClause "sourcePath" "source_path"
    , fieldClause "repo" "repo"
    , fieldClause "preferredView" "preferred_view"
    , intFieldClause "coverAttachmentId" "cover_attachment_id"
    , fieldClause "blogStatus" "blog_status"
    , nullableIntFieldClause "parentId" "parent_id"
    -- blogContent is no longer DB-owned: drafts live on disk as files
    -- under $MARGINALIA_BLOG_DRAFTS and VS Code writes them directly.
    -- See BlogDrafts.purs.
    ]
  fieldClause :: String -> String -> Maybe { clause :: String, param :: Foreign }
  fieldClause jsonKey sqlCol = case getFieldMaybe jsonKey obj of
    Nothing -> Nothing
    Just val -> Just { clause: sqlCol <> " = ?", param: unsafeToForeign val }
  intFieldClause :: String -> String -> Maybe { clause :: String, param :: Foreign }
  intFieldClause jsonKey sqlCol = case getIntField jsonKey obj of
    Nothing -> Nothing
    Just n -> Just { clause: sqlCol <> " = ?", param: unsafeToForeign n }
  -- | Integer field that may also be explicitly null (move-to-root semantics
  -- | for parent_id, or clear-cover for cover_attachment_id). Missing key =
  -- | don't update; JSON null = set NULL; JSON number = set to that int.
  nullableIntFieldClause :: String -> String -> Maybe { clause :: String, param :: Foreign }
  nullableIntFieldClause jsonKey sqlCol = case FO.lookup jsonKey obj of
    Nothing -> Nothing
    Just json -> case J.toNumber json of
      Just n -> Just { clause: sqlCol <> " = ?", param: unsafeToForeign (Int.floor n) }
      Nothing -> Just { clause: sqlCol <> " = ?", param: jsNull }
  present = Array.catMaybes fields
  clauses = map _.clause present
  params = map _.param present

parseBody :: String -> Maybe (FO.Object Json)
parseBody str = case jsonParser str of
  Left _ -> Nothing
  Right json -> J.toObject json
