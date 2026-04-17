module Opener
  ( openProject
  ) where

import Prelude

import Data.Maybe (Maybe(..))
import Data.Nullable (Nullable, toMaybe)
import Database.DuckDB (Database, queryAllParams, firstRow)
import Effect (Effect)
import Effect.Aff (Aff)
import Effect.Class (liftEffect)
import Foreign (Foreign, unsafeToForeign, unsafeFromForeign)
import HTTPurple (Response, ok', badRequest', notFound)
import HTTPurple.Headers (ResponseHeaders, headers)

jsonHeaders :: ResponseHeaders
jsonHeaders = headers
  { "Content-Type": "application/json"
  , "Access-Control-Allow-Origin": "*"
  }

foreign import resolveSourcePath_ :: String -> Nullable String
foreign import openInApp_ :: String -> String -> Effect Foreign

-- | Read a string field from a row. Returns "" if missing/null.
-- | Duplicated from Projects.js to avoid cross-FFI import issues.
foreign import getRowString_ :: String -> Foreign -> String

-- | Handle `POST /api/projects/:id/open?app=finder|vscode|iterm`.
-- | Looks up the project's source_path, resolves it to absolute,
-- | and shells out to the requested app.
openProject :: Database -> Int -> String -> Aff Response
openProject db projectId app = do
  rows <- queryAllParams db
    "SELECT source_path FROM projects WHERE id = ?"
    [ unsafeToForeign projectId ]
  case firstRow rows of
    Nothing -> notFound
    Just row -> do
      let sourcePath = getRowString_ "source_path" row
      case toMaybe (resolveSourcePath_ sourcePath) of
        Nothing ->
          badRequest' jsonHeaders """{"error": "Project has no source_path"}"""
        Just absPath -> do
          result <- liftEffect (openInApp_ app absPath)
          let r :: { kind :: String, path :: String, error :: String }
              r = unsafeFromForeign result
          case r.kind of
            "ok" ->
              ok' jsonHeaders ("{\"ok\": true, \"path\": \"" <> r.path <> "\"}")
            _ ->
              badRequest' jsonHeaders ("{\"error\": \"" <> r.error <> "\"}")
