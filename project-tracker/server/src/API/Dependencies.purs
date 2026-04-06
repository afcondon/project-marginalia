-- | Dependency CRUD API endpoints
-- |
-- | Handles listing, creating, and deleting project dependencies.
-- | Body parsing and SQL construction in PureScript; JSON response
-- | serialization via FFI (marshalling Foreign objects from DuckDB).
module API.Dependencies
  ( listDependencies
  , createDependency
  , deleteDependency
  ) where

import Prelude

import Data.Argonaut.Core (Json)
import Data.Argonaut.Core (toObject, toString, toNumber) as J
import Data.Argonaut.Parser (jsonParser)
import Data.Either (Either(..))
import Data.Int (fromNumber) as Int
import Data.Maybe (Maybe(..))
import Database.DuckDB (Database, Rows, queryAllParams, run, firstRow, isEmpty)
import Effect.Aff (Aff)
import Foreign (Foreign, unsafeToForeign)
import Foreign.Object (Object, lookup) as FO
import HTTPurple (Response, ok', badRequest', notFound, conflict')
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

foreign import buildDependencyListJson :: Rows -> String
foreign import buildDependencyJson :: Foreign -> String

-- =============================================================================
-- Helpers
-- =============================================================================

parseBody :: String -> Maybe (FO.Object Json)
parseBody str = case jsonParser str of
  Left _ -> Nothing
  Right json -> J.toObject json

getStringField :: String -> FO.Object Json -> Maybe String
getStringField key obj = case FO.lookup key obj of
  Nothing -> Nothing
  Just json -> J.toString json

getIntField :: String -> FO.Object Json -> Maybe Int
getIntField key obj = case FO.lookup key obj of
  Nothing -> Nothing
  Just json -> case J.toNumber json of
    Nothing -> Nothing
    Just n -> Int.fromNumber n

isValidDepType :: String -> Boolean
isValidDepType t = t == "blocks" || t == "informs" || t == "feeds_into"

-- =============================================================================
-- GET /api/dependencies
-- =============================================================================

listDependencies :: Database -> Maybe String -> Aff Response
listDependencies db mType = do
  let typeClause = case mType of
        Just _ -> " AND dependency_type = ?"
        Nothing -> ""
  let sql = "SELECT * FROM dependency_graph WHERE 1=1" <> typeClause <> " ORDER BY blocker_id, blocked_id"
  let params = case mType of
        Just t -> [ unsafeToForeign t ]
        Nothing -> []
  rows <- queryAllParams db sql params
  ok' jsonHeaders (buildDependencyListJson rows)

-- =============================================================================
-- POST /api/dependencies
-- =============================================================================

createDependency :: Database -> String -> Aff Response
createDependency db bodyStr = case parseBody bodyStr of
  Nothing -> badRequest' jsonHeaders """{"error": "Invalid JSON body"}"""
  Just obj ->
    case getIntField "blockerId" obj, getIntField "blockedId" obj of
      Nothing, _ ->
        badRequest' jsonHeaders """{"error": "blockerId is required and must be an integer"}"""
      _, Nothing ->
        badRequest' jsonHeaders """{"error": "blockedId is required and must be an integer"}"""
      Just blockerId, Just blockedId -> do
        let depType = case getStringField "type" obj of
              Just t -> t
              Nothing -> "blocks"
        if not (isValidDepType depType)
          then badRequest' jsonHeaders """{"error": "type must be one of: blocks, informs, feeds_into"}"""
          else do
            blockerRows <- queryAllParams db "SELECT id FROM projects WHERE id = ?" [ unsafeToForeign blockerId ]
            blockedRows <- queryAllParams db "SELECT id FROM projects WHERE id = ?" [ unsafeToForeign blockedId ]
            if isEmpty blockerRows || isEmpty blockedRows
              then notFound
              else do
                existingRows <- queryAllParams db
                  "SELECT 1 FROM dependencies WHERE blocker_id = ? AND blocked_id = ?"
                  [ unsafeToForeign blockerId, unsafeToForeign blockedId ]
                if not (isEmpty existingRows)
                  then conflict' jsonHeaders """{"error": "Dependency already exists"}"""
                  else do
                    run db
                      "INSERT INTO dependencies (blocker_id, blocked_id, dependency_type) VALUES (?, ?, ?)"
                      [ unsafeToForeign blockerId, unsafeToForeign blockedId, unsafeToForeign depType ]
                    createdRows <- queryAllParams db
                      "SELECT * FROM dependency_graph WHERE blocker_id = ? AND blocked_id = ?"
                      [ unsafeToForeign blockerId, unsafeToForeign blockedId ]
                    case firstRow createdRows of
                      Nothing -> badRequest' jsonHeaders """{"error": "Failed to retrieve created dependency"}"""
                      Just dep -> ok' jsonHeaders (buildDependencyJson dep)

-- =============================================================================
-- DELETE /api/dependencies/:blocker/:blocked
-- =============================================================================

deleteDependency :: Database -> Int -> Int -> Aff Response
deleteDependency db blockerId blockedId = do
  existing <- queryAllParams db
    "SELECT 1 FROM dependencies WHERE blocker_id = ? AND blocked_id = ?"
    [ unsafeToForeign blockerId, unsafeToForeign blockedId ]
  if isEmpty existing
    then notFound
    else do
      run db
        "DELETE FROM dependencies WHERE blocker_id = ? AND blocked_id = ?"
        [ unsafeToForeign blockerId, unsafeToForeign blockedId ]
      ok' jsonHeaders """{"deleted": true}"""
