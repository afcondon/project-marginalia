-- | Klapaucius blog workbench — API server
module Klapaucius.Server.Main where

import Prelude

import API.Posts as Posts
import API.Sources as Sources
import Control.Monad.Error.Class (try)
import Data.Either (Either(..))
import Data.Generic.Rep (class Generic)
import Data.Maybe (Maybe(..))
import Database.DuckDB as DB
import Effect (Effect)
import Effect.Aff (launchAff_)
import Effect.Class (liftEffect)
import Effect.Console (log)
import Effect.Exception (message)
import Effect.Ref as Ref
import Foreign.Object as Object
import HTTPurple (Method(..), serve, ok, ok', toString)
import HTTPurple.Headers (headers)
import Node.Encoding (Encoding(..))
import Node.FS.Sync (readTextFile)
import Routing.Duplex (RouteDuplex', root, path, int, segment, suffix)
import Routing.Duplex.Generic (noArgs, sum)

-- =============================================================================
-- Routes
-- =============================================================================

data Route
  = Posts
  | PostById Int
  | PostAssets Int
  | PostOpen Int
  | Stats
  | Categories
  -- Source browsing
  | SourceTickets
  | SourcePhotos
  | SourceFromPhoto
  | SourceFromMusic
  | BrowseDirectory

derive instance Generic Route _

route :: RouteDuplex' Route
route = root $ sum
  { "Posts": path "api/posts" noArgs
  , "PostById": path "api/posts" (int segment)
  , "PostAssets": path "api/posts" (suffix (int segment) "assets")
  , "PostOpen": path "api/posts" (suffix (int segment) "open")
  , "Stats": path "api/stats" noArgs
  , "Categories": path "api/categories" noArgs
  , "SourceTickets": path "api/sources/tickets" noArgs
  , "SourcePhotos": path "api/sources/photos" noArgs
  , "SourceFromPhoto": path "api/sources/from-photo" noArgs
  , "SourceFromMusic": path "api/sources/from-music" noArgs
  , "BrowseDirectory": path "api/sources/browse" noArgs
  }

-- =============================================================================
-- Server
-- =============================================================================

dbPath :: String
dbPath = "./database/klapaucius.duckdb"

schemaPath :: String
schemaPath = "./database/schema.sql"

main :: Effect Unit
main = launchAff_ do
  db <- DB.openDB dbPath
  dbRef <- liftEffect $ Ref.new db
  liftEffect $ log $ "Connected to database: " <> dbPath

  mSchemaSrc <- liftEffect $ try $ readTextFile UTF8 schemaPath
  case mSchemaSrc of
    Left err -> liftEffect $ log $
      "Warning: could not read " <> schemaPath <> ": " <> message err
    Right sql -> do
      DB.exec db sql
      liftEffect $ log "Schema applied from schema.sql"

  liftEffect do
    _ <- serve { port: 3400 } { route, router: mkRouter dbRef }
    log "Klapaucius blog workbench running on http://localhost:3400"
    log ""
    log "Endpoints:"
    log "  GET    /api/posts              - List blog posts (filterable)"
    log "  POST   /api/posts              - Create a blog post"
    log "  GET    /api/posts/:id          - Get post detail"
    log "  PUT    /api/posts/:id          - Update a post"
    log "  DELETE /api/posts/:id          - Delete a post"
    log "  GET    /api/posts/:id/assets   - List assets for a post"
    log "  POST   /api/posts/:id/assets   - Upload an asset"
    log "  GET    /api/stats              - Aggregate statistics"
    log "  GET    /api/categories         - List categories with counts"
  where
  corsHeaders = headers
    { "Access-Control-Allow-Origin": "*"
    , "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS"
    , "Access-Control-Allow-Headers": "Content-Type"
    }
  jsonHeaders = headers
    { "Content-Type": "application/json; charset=utf-8"
    , "Access-Control-Allow-Origin": "*"
    }
  mkRouter dbRef { route: r, query, method, body } = do
    db <- liftEffect $ Ref.read dbRef
    case r of
      Posts -> case method of
        Get -> do
          let mCategory = Object.lookup "category" query
          let mStatus = Object.lookup "status" query
          Posts.listPosts db mCategory mStatus
        Post -> do
          bodyStr <- toString body
          Posts.createPost db bodyStr
        Options -> ok' corsHeaders ""
        _ -> ok """{ "error": "Method not allowed" }"""

      PostById postId -> case method of
        Get -> Posts.getPost db postId
        Put -> do
          bodyStr <- toString body
          Posts.updatePost db postId bodyStr
        Delete -> Posts.deletePost db postId
        Options -> ok' corsHeaders ""
        _ -> ok """{ "error": "Method not allowed" }"""

      PostAssets postId -> case method of
        Get -> Posts.listAssets db postId
        Post -> do
          bodyStr <- toString body
          Posts.saveAsset db postId bodyStr
        Options -> ok' corsHeaders ""
        _ -> ok """{ "error": "Method not allowed" }"""

      PostOpen postId -> case method of
        Post -> Posts.openInVSCode db postId
        Options -> ok' corsHeaders ""
        _ -> ok """{ "error": "Method not allowed" }"""

      Stats -> case method of
        Get -> Posts.getStats db
        Options -> ok' corsHeaders ""
        _ -> ok """{ "error": "Method not allowed" }"""

      Categories -> case method of
        Get -> Posts.getCategories db
        Options -> ok' corsHeaders ""
        _ -> ok """{ "error": "Method not allowed" }"""

      -- Source browsing
      SourceTickets -> case method of
        Get -> Sources.listTickets
        Options -> ok' corsHeaders ""
        _ -> ok """{ "error": "Method not allowed" }"""

      SourcePhotos -> case method of
        Get -> do
          let mDate = Object.lookup "date" query
          case mDate of
            Nothing -> ok' jsonHeaders """{"error": "Missing ?date= parameter"}"""
            Just d -> Sources.listPhotosByDate d
        Options -> ok' corsHeaders ""
        _ -> ok """{ "error": "Method not allowed" }"""

      SourceFromPhoto -> case method of
        Post -> do
          bodyStr <- toString body
          Sources.createFromPhoto db bodyStr
        Options -> ok' corsHeaders ""
        _ -> ok """{ "error": "Method not allowed" }"""

      SourceFromMusic -> case method of
        Post -> do
          bodyStr <- toString body
          Sources.createFromMusic db bodyStr
        Options -> ok' corsHeaders ""
        _ -> ok """{ "error": "Method not allowed" }"""

      BrowseDirectory -> case method of
        Get -> do
          case Object.lookup "path" query of
            Nothing -> ok' jsonHeaders """{"error": "Missing ?path= parameter"}"""
            Just dirPath -> Sources.listDirectory dirPath
        Options -> ok' corsHeaders ""
        _ -> ok """{ "error": "Method not allowed" }"""
