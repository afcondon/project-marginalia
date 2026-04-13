-- | Blog post CRUD API endpoints
module API.Posts
  ( listPosts
  , getPost
  , createPost
  , updatePost
  , deletePost
  , listAssets
  , saveAsset
  , getStats
  , getCategories
  , openInVSCode
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
import Foreign (Foreign, unsafeToForeign)
import Foreign.Object as FO
import HTTPurple (Response, ok, ok', notFound, badRequest')
import HTTPurple (headers) as H

jsonHeaders :: _
jsonHeaders = H.headers
  { "Content-Type": "application/json; charset=utf-8"
  , "Access-Control-Allow-Origin": "*"
  }

-- =============================================================================
-- FFI
-- =============================================================================

foreign import buildPostListJson :: Rows -> String
foreign import buildPostDetailJson :: Foreign -> String
foreign import getRowString_ :: String -> Foreign -> String
foreign import getRowInt_ :: String -> Foreign -> Int
foreign import openPostInVSCode :: String -> String -> String -> Effect String
foreign import buildStatsJson :: Rows -> Rows -> String
foreign import buildCategoriesJson :: Rows -> String

-- =============================================================================
-- GET /api/posts
-- =============================================================================

listPosts :: Database -> Maybe String -> Maybe String -> Aff Response
listPosts db mCategory mStatus = do
  let baseSql = "SELECT * FROM blog_posts"
  let whereClauses = Array.catMaybes
        [ map (\_ -> "category = ?") mCategory
        , map (\_ -> "status = ?") mStatus
        ]
  let whereStr = case whereClauses of
        [] -> ""
        cs -> " WHERE " <> Array.intercalate " AND " cs
  let orderStr = """ ORDER BY
        CASE status
          WHEN 'drafted'         THEN 1
          WHEN 'wanted_priority' THEN 2
          WHEN 'wanted'          THEN 3
          WHEN 'published'       THEN 4
          WHEN 'not_needed'      THEN 5
          ELSE 6
        END, updated_at DESC"""
  let params = Array.catMaybes
        [ map unsafeToForeign mCategory
        , map unsafeToForeign mStatus
        ]
  rows <- queryAllParams db (baseSql <> whereStr <> orderStr) params
  -- Enrich with file info from disk
  enriched <- liftEffect $ enrichPostRows rows
  ok' jsonHeaders enriched

foreign import enrichPostRows :: Rows -> Effect String

-- =============================================================================
-- GET /api/posts/:id
-- =============================================================================

getPost :: Database -> Int -> Aff Response
getPost db postId = do
  rows <- queryAllParams db
    "SELECT * FROM blog_posts WHERE id = ?"
    [ unsafeToForeign postId ]
  case firstRow rows of
    Nothing -> notFound
    Just row -> ok' jsonHeaders (buildPostDetailJson row)

-- =============================================================================
-- POST /api/posts
-- =============================================================================

createPost :: Database -> String -> Aff Response
createPost db bodyStr = case parseBody bodyStr of
  Nothing -> badRequest' jsonHeaders """{"error": "Invalid JSON body"}"""
  Just obj -> do
    let category = fromMaybe "freestanding" (getField "category" obj)
    let title = fromMaybe "" (getField "title" obj)
    let slug = fromMaybe "" (getField "slug" obj)
    let status = fromMaybe "wanted" (getField "status" obj)
    let sourceType = getField "sourceType" obj
    let sourceId = getField "sourceId" obj
    let sourceMeta = getField "sourceMeta" obj
    if title == "" || slug == ""
      then badRequest' jsonHeaders """{"error": "Missing 'title' and/or 'slug'"}"""
      else do
        run db
          """INSERT INTO blog_posts (category, slug, title, status, source_type, source_id, source_meta)
             VALUES (?, ?, ?, ?, ?, ?, ?)"""
          [ unsafeToForeign category
          , unsafeToForeign slug
          , unsafeToForeign title
          , unsafeToForeign status
          , unsafeToForeign (fromMaybe "" sourceType)
          , unsafeToForeign (fromMaybe "" sourceId)
          , unsafeToForeign (fromMaybe "" sourceMeta)
          ]
        -- Return the created post
        rows <- queryAllParams db
          "SELECT * FROM blog_posts WHERE category = ? AND slug = ?"
          [ unsafeToForeign category, unsafeToForeign slug ]
        case firstRow rows of
          Nothing -> ok' jsonHeaders """{"ok": true}"""
          Just row -> ok' jsonHeaders (buildPostDetailJson row)

-- =============================================================================
-- PUT /api/posts/:id
-- =============================================================================

updatePost :: Database -> Int -> String -> Aff Response
updatePost db postId bodyStr = case parseBody bodyStr of
  Nothing -> badRequest' jsonHeaders """{"error": "Invalid JSON body"}"""
  Just obj -> do
    let updates = buildUpdateClauses obj
    if Array.null updates.clauses
      then badRequest' jsonHeaders """{"error": "No fields to update"}"""
      else do
        let setClauses = Array.intercalate ", " updates.clauses <> ", updated_at = current_timestamp"
        let sql = "UPDATE blog_posts SET " <> setClauses <> " WHERE id = ?"
        run db sql (updates.params <> [ unsafeToForeign postId ])
        rows <- queryAllParams db "SELECT * FROM blog_posts WHERE id = ?" [ unsafeToForeign postId ]
        case firstRow rows of
          Nothing -> notFound
          Just row -> ok' jsonHeaders (buildPostDetailJson row)

-- =============================================================================
-- DELETE /api/posts/:id
-- =============================================================================

deletePost :: Database -> Int -> Aff Response
deletePost db postId = do
  run db "DELETE FROM blog_posts WHERE id = ?" [ unsafeToForeign postId ]
  ok' jsonHeaders """{"ok": true}"""

-- =============================================================================
-- POST /api/posts/:id/open — open in VS Code
-- =============================================================================

openInVSCode :: Database -> Int -> Aff Response
openInVSCode db postId = do
  rows <- queryAllParams db
    "SELECT category, slug, title FROM blog_posts WHERE id = ?"
    [ unsafeToForeign postId ]
  case firstRow rows of
    Nothing -> notFound
    Just row -> do
      let category = getRowString_ "category" row
      let slug = getRowString_ "slug" row
      let title = getRowString_ "title" row
      result <- liftEffect $ openPostInVSCode category slug title
      ok' jsonHeaders result

-- =============================================================================
-- GET /api/posts/:id/assets
-- =============================================================================

listAssets :: Database -> Int -> Aff Response
listAssets db postId = do
  rows <- queryAllParams db
    "SELECT category, slug FROM blog_posts WHERE id = ?"
    [ unsafeToForeign postId ]
  case firstRow rows of
    Nothing -> notFound
    Just row -> do
      let category = getRowString_ "category" row
      let slug = getRowString_ "slug" row
      result <- liftEffect $ listAssetsJson category slug
      ok' jsonHeaders result

foreign import listAssetsJson :: String -> String -> Effect String

-- =============================================================================
-- POST /api/posts/:id/assets
-- =============================================================================

saveAsset :: Database -> Int -> String -> Aff Response
saveAsset db postId bodyStr = case parseBody bodyStr of
  Nothing -> badRequest' jsonHeaders """{"error": "Invalid JSON body"}"""
  Just obj -> do
    rows <- queryAllParams db
      "SELECT category, slug FROM blog_posts WHERE id = ?"
      [ unsafeToForeign postId ]
    case firstRow rows of
      Nothing -> notFound
      Just row -> do
        let category = getRowString_ "category" row
        let slug = getRowString_ "slug" row
        case getField "filename" obj, getField "data" obj of
          Just filename, Just base64Data -> do
            result <- liftEffect $ saveAssetToDisk category slug filename base64Data
            ok' jsonHeaders result
          _, _ -> badRequest' jsonHeaders """{"error": "Missing 'filename' and/or 'data'"}"""

foreign import saveAssetToDisk :: String -> String -> String -> String -> Effect String

-- =============================================================================
-- GET /api/stats
-- =============================================================================

getStats :: Database -> Aff Response
getStats db = do
  statusRows <- queryAll db
    "SELECT status, count(*) as cnt FROM blog_posts GROUP BY status ORDER BY status"
  categoryRows <- queryAll db
    "SELECT category, count(*) as cnt FROM blog_posts GROUP BY category ORDER BY category"
  ok' jsonHeaders (buildStatsJson statusRows categoryRows)

-- =============================================================================
-- GET /api/categories
-- =============================================================================

getCategories :: Database -> Aff Response
getCategories db = do
  rows <- queryAll db
    "SELECT category, count(*) as cnt FROM blog_posts GROUP BY category ORDER BY category"
  ok' jsonHeaders (buildCategoriesJson rows)

-- =============================================================================
-- Helpers
-- =============================================================================

type UpdateClauses = { clauses :: Array String, params :: Array Foreign }

buildUpdateClauses :: FO.Object Json -> UpdateClauses
buildUpdateClauses obj = { clauses, params }
  where
  fields =
    [ fieldClause "title" "title"
    , fieldClause "status" "status"
    , fieldClause "category" "category"
    , fieldClause "slug" "slug"
    , fieldClause "sourceType" "source_type"
    , fieldClause "sourceId" "source_id"
    , fieldClause "sourceMeta" "source_meta"
    ]
  fieldClause :: String -> String -> Maybe { clause :: String, param :: Foreign }
  fieldClause jsonKey sqlCol = case getField jsonKey obj of
    Nothing -> Nothing
    Just val -> Just { clause: sqlCol <> " = ?", param: unsafeToForeign val }
  present = Array.catMaybes fields
  clauses = map _.clause present
  params = map _.param present

parseBody :: String -> Maybe (FO.Object Json)
parseBody str = case jsonParser str of
  Left _ -> Nothing
  Right json -> J.toObject json

getField :: String -> FO.Object Json -> Maybe String
getField key obj = J.toString =<< FO.lookup key obj
