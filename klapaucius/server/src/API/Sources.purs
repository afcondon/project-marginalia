-- | Source browsing endpoints — tickets, photos, music from infovore
module API.Sources
  ( listTickets
  , listPhotosByDate
  , createFromPhoto
  , createFromMusic
  , listDirectory
  ) where

import Prelude

import Data.Argonaut.Core (Json)
import Data.Argonaut.Core (toObject, toString) as J
import Data.Argonaut.Parser (jsonParser)
import Data.Array as Array
import Data.Either (Either(..))
import Data.Maybe (Maybe(..), fromMaybe)
import Database.DuckDB (Database, Rows, queryAll, queryAllParams, run, firstRow)
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

-- | Read and parse ticket-reviewed.json, return as JSON string
foreign import readTicketsJson :: Effect String

-- | Query photos catalog.db for a given date (YYYY-MM-DD or MM-DD).
-- | Returns JSON string with array of photo records.
foreign import queryPhotosJson :: String -> Effect String

-- | Copy a photo file into a post's asset directory, creating the post dir.
-- | Args: category, slug, source photo path.
-- | Returns JSON: { ok, filename, markdown } or { error }.
foreign import importPhotoAsset :: String -> String -> String -> Effect String

-- | Look up music track/album info from library.db by file path.
-- | Returns JSON: { artist, album, name, year, ... } or null.
foreign import lookupMusicByPath :: String -> Effect String

-- | List directory contents, sorted dirs-first then alphabetically.
-- | Returns JSON: { items: Array { name, isDirectory, path }, count, path }.
foreign import listDirectoryJson :: String -> Effect String

-- =============================================================================
-- GET /api/sources/tickets — all concert tickets sorted by artist
-- =============================================================================

listTickets :: Aff Response
listTickets = do
  json <- liftEffect readTicketsJson
  ok' jsonHeaders json

-- =============================================================================
-- GET /api/sources/photos?date=YYYY-MM-DD or ?date=MM-DD
-- =============================================================================

listPhotosByDate :: String -> Aff Response
listPhotosByDate dateStr = do
  json <- liftEffect $ queryPhotosJson dateStr
  ok' jsonHeaders json

-- =============================================================================
-- POST /api/sources/from-photo — create a post from a photo path
-- =============================================================================

createFromPhoto :: Database -> String -> Aff Response
createFromPhoto db bodyStr = case parseBody bodyStr of
  Nothing -> badRequest' jsonHeaders """{"error": "Invalid JSON body"}"""
  Just obj -> do
    let mPath = getField "path" obj
    let mTitle = getField "title" obj
    let mSlug = getField "slug" obj
    case mPath, mTitle, mSlug of
      Just photoPath, Just title, Just slug -> do
        -- Create the DB record
        run db
          """INSERT INTO blog_posts (category, slug, title, status, source_type, source_id)
             VALUES ('photos', ?, ?, 'drafted', 'infovore_photos', ?)"""
          [ unsafeToForeign slug
          , unsafeToForeign title
          , unsafeToForeign photoPath
          ]
        -- Copy the photo into the post's asset directory
        result <- liftEffect $ importPhotoAsset "photos" slug photoPath
        ok' jsonHeaders result
      _, _, _ -> badRequest' jsonHeaders """{"error": "Missing 'path', 'title', and/or 'slug'"}"""

-- =============================================================================
-- POST /api/sources/from-music — create a post from a music path
-- =============================================================================

createFromMusic :: Database -> String -> Aff Response
createFromMusic db bodyStr = case parseBody bodyStr of
  Nothing -> badRequest' jsonHeaders """{"error": "Invalid JSON body"}"""
  Just obj -> do
    let mPath = getField "path" obj
    let mTitle = getField "title" obj
    let mSlug = getField "slug" obj
    case mPath, mTitle, mSlug of
      Just musicPath, Just title, Just slug -> do
        -- Look up metadata from library.db
        metaJson <- liftEffect $ lookupMusicByPath musicPath
        run db
          """INSERT INTO blog_posts (category, slug, title, status, source_type, source_id, source_meta)
             VALUES ('music', ?, ?, 'drafted', 'infovore_music', ?, ?)"""
          [ unsafeToForeign slug
          , unsafeToForeign title
          , unsafeToForeign musicPath
          , unsafeToForeign metaJson
          ]
        ok' jsonHeaders ("{\"ok\": true, \"slug\": \"" <> slug <> "\"}")
      _, _, _ -> badRequest' jsonHeaders """{"error": "Missing 'path', 'title', and/or 'slug'"}"""

-- =============================================================================
-- GET /api/sources/browse?path=<absolute-path>
-- =============================================================================

listDirectory :: String -> Aff Response
listDirectory dirPath = do
  json <- liftEffect $ listDirectoryJson dirPath
  ok' jsonHeaders json

-- =============================================================================
-- Helpers
-- =============================================================================

parseBody :: String -> Maybe (FO.Object Json)
parseBody str = case jsonParser str of
  Left _ -> Nothing
  Right json -> J.toObject json

getField :: String -> FO.Object Json -> Maybe String
getField key obj = J.toString =<< FO.lookup key obj
