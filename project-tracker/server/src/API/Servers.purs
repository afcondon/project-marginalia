-- | Project server registry — HTTP endpoints.
-- |
-- | The port registry: which projects claim which ports, with roles, URLs,
-- | and start commands. Callers can list, add, remove, and ask for a suggested
-- | free port.
-- |
-- | All pure PureScript: typed decoders for DB rows, typed encoders using
-- | argonaut-core constructors for JSON output, standard Data.Array primitives
-- | for grouping and collision detection. Zero new FFI beyond what already
-- | exists in the DuckDB wrapper.
module API.Servers
  ( listPorts
  , listServersForProject
  , addServer
  , deleteServer
  , suggestPort
  ) where

import Prelude

import Control.Monad.Except (runExcept)
import Data.Argonaut.Core (Json)
import Data.Argonaut.Core as J
import Data.Argonaut.Parser (jsonParser)
import Data.Array (catMaybes, filter, groupBy, length, sort, sortBy, uncons) as Array
import Data.Array.NonEmpty (head, length, toArray) as NEA
import Data.Either (Either(..))
import Data.Function (on)
import Data.Int (floor, toNumber) as Int
import Data.Maybe (Maybe(..), maybe)
import Data.Nullable (toNullable)
import Data.Traversable (traverse)
import Data.Tuple.Nested ((/\))
import Database.DuckDB (Database, queryAll, queryAllParams, run)
import Effect.Aff (Aff)
import Foreign (F, Foreign, readInt, readNullOrUndefined, readString, unsafeToForeign)
import Foreign.Index (readProp)
import Foreign.Object (fromFoldable) as Object
import Foreign.Object (Object, lookup) as FO
import HTTPurple (Response, ok', badRequest')
import HTTPurple.Headers (ResponseHeaders, headers)

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

type ServerRow =
  { id :: Int
  , projectId :: Int
  , projectName :: String
  , projectSlug :: Maybe String
  , role :: String
  , port :: Maybe Int
  , url :: Maybe String
  , startCommand :: Maybe String
  , description :: Maybe String
  }

-- | Decode a single DB row into a typed ServerRow using the Foreign module's
-- | typed readers. Each field is read by name with appropriate nullability.
decodeServerRow :: Foreign -> F ServerRow
decodeServerRow f = do
  id <- readProp "id" f >>= readInt
  projectId <- readProp "project_id" f >>= readInt
  projectName <- readProp "project_name" f >>= readString
  projectSlug <- readProp "project_slug" f >>= readNullOrUndefined >>= traverse readString
  role <- readProp "role" f >>= readString
  port <- readProp "port" f >>= readNullOrUndefined >>= traverse readInt
  url <- readProp "url" f >>= readNullOrUndefined >>= traverse readString
  startCommand <- readProp "start_command" f >>= readNullOrUndefined >>= traverse readString
  description <- readProp "description" f >>= readNullOrUndefined >>= traverse readString
  pure { id, projectId, projectName, projectSlug, role, port, url, startCommand, description }

-- | Decode a result array, dropping any rows that fail to decode.
-- | For a stricter pipeline we'd collect and return errors; for now the
-- | tolerance keeps the endpoint resilient to schema drift.
decodeServerRows :: Array Foreign -> Array ServerRow
decodeServerRows = Array.catMaybes <<< map attempt
  where
  attempt :: Foreign -> Maybe ServerRow
  attempt f = case runExcept (decodeServerRow f) of
    Left _ -> Nothing
    Right r -> Just r

-- =============================================================================
-- Encoder — ServerRow to Json using argonaut constructors
-- =============================================================================

encodeServerRow :: ServerRow -> Json
encodeServerRow r = J.fromObject $ Object.fromFoldable
  [ "id" /\ J.fromNumber (Int.toNumber r.id)
  , "projectId" /\ J.fromNumber (Int.toNumber r.projectId)
  , "projectName" /\ J.fromString r.projectName
  , "projectSlug" /\ maybeString r.projectSlug
  , "role" /\ J.fromString r.role
  , "port" /\ maybe J.jsonNull (J.fromNumber <<< Int.toNumber) r.port
  , "url" /\ maybeString r.url
  , "startCommand" /\ maybeString r.startCommand
  , "description" /\ maybeString r.description
  ]
  where
  maybeString = maybe J.jsonNull J.fromString

-- | Build the port registry envelope:
-- |   { "servers": [...], "count": N, "collisions": { "3001": ["a", "b"], ... } }
encodePortRegistry :: Array ServerRow -> String
encodePortRegistry rows =
  let envelope = J.fromObject $ Object.fromFoldable
        [ "servers" /\ J.fromArray (map encodeServerRow rows)
        , "count" /\ J.fromNumber (Int.toNumber (Array.length rows))
        , "collisions" /\ encodeCollisions rows
        ]
  in J.stringify envelope

-- | Detect ports claimed by more than one server and return them as a
-- | JSON object keyed by port, with values arrays of claimant labels.
encodeCollisions :: Array ServerRow -> Json
encodeCollisions rows =
  let pairs = Array.catMaybes (map liftPort rows)
      sorted = Array.sortBy (compare `on` _.port) pairs
      grouped = Array.groupBy (eq `on` _.port) sorted
      conflicts = Array.filter (\g -> NEA.length g > 1) grouped
  in J.fromObject (Object.fromFoldable (map toEntry conflicts))
  where
  liftPort :: ServerRow -> Maybe { port :: Int, claimant :: String }
  liftPort r = case r.port of
    Nothing -> Nothing
    Just p -> Just { port: p, claimant: r.projectName <> "/" <> r.role }

  toEntry group =
    let port = (NEA.head group).port
        claimants = map _.claimant (NEA.toArray group)
    in show port /\ J.fromArray (map J.fromString claimants)

-- =============================================================================
-- GET /api/ports
-- =============================================================================

listPorts :: Database -> Aff Response
listPorts db = do
  rows <- queryAll db
    """SELECT s.id, s.project_id, p.name AS project_name, p.slug AS project_slug,
              s.role, s.port, s.url, s.start_command, s.description
       FROM project_servers s
       JOIN projects p ON p.id = s.project_id
       WHERE s.port IS NOT NULL
       ORDER BY s.port, s.id"""
  let decoded = decodeServerRows rows
  ok' jsonHeaders (encodePortRegistry decoded)

-- =============================================================================
-- GET /api/projects/:id/servers
-- =============================================================================

listServersForProject :: Database -> Int -> Aff Response
listServersForProject db projectId = do
  rows <- queryAllParams db
    """SELECT s.id, s.project_id, p.name AS project_name, p.slug AS project_slug,
              s.role, s.port, s.url, s.start_command, s.description
       FROM project_servers s
       JOIN projects p ON p.id = s.project_id
       WHERE s.project_id = ?
       ORDER BY s.port NULLS LAST, s.id"""
    [ unsafeToForeign projectId ]
  let decoded = decodeServerRows rows
  ok' jsonHeaders (J.stringify (J.fromArray (map encodeServerRow decoded)))

-- =============================================================================
-- POST /api/projects/:id/servers
-- =============================================================================
-- | Body: { "role": "api", "port": 3100, "url": "...", "startCommand": "...",
-- |         "description": "..." }
-- |
-- | All fields except `role` are optional. Nullable columns use Data.Nullable
-- | to correctly serialize to SQL NULL when the Maybe is Nothing.

addServer :: Database -> Int -> String -> Aff Response
addServer db projectId bodyStr = case parseBody bodyStr of
  Nothing -> badRequest' jsonHeaders """{"error": "Invalid JSON body"}"""
  Just obj -> case getStringField "role" obj of
    Nothing -> badRequest' jsonHeaders """{"error": "Missing 'role' field"}"""
    Just role -> do
      let mPort = getIntField "port" obj
          mUrl = getStringField "url" obj
          mCmd = getStringField "startCommand" obj
          mDesc = getStringField "description" obj

      run db
        """INSERT INTO project_servers
               (project_id, role, port, url, start_command, description)
           VALUES (?, ?, ?, ?, ?, ?)"""
        [ unsafeToForeign projectId
        , unsafeToForeign role
        , unsafeToForeign (toNullable mPort)
        , unsafeToForeign (toNullable mUrl)
        , unsafeToForeign (toNullable mCmd)
        , unsafeToForeign (toNullable mDesc)
        ]

      -- Fetch and return the newly-inserted row
      rows <- queryAll db
        """SELECT s.id, s.project_id, p.name AS project_name, p.slug AS project_slug,
                  s.role, s.port, s.url, s.start_command, s.description
           FROM project_servers s JOIN projects p ON p.id = s.project_id
           WHERE s.id = (SELECT MAX(id) FROM project_servers)"""
      case Array.uncons (decodeServerRows rows) of
        Nothing -> ok' jsonHeaders """{"ok": true}"""
        Just { head } -> ok' jsonHeaders (J.stringify (encodeServerRow head))

-- =============================================================================
-- DELETE /api/servers/:id
-- =============================================================================

deleteServer :: Database -> Int -> Aff Response
deleteServer db serverId = do
  run db
    "DELETE FROM project_servers WHERE id = ?"
    [ unsafeToForeign serverId ]
  ok' jsonHeaders ("{\"ok\": true, \"deleted\": " <> show serverId <> "}")

-- =============================================================================
-- GET /api/ports/suggest — next free port from 3000 upward
-- =============================================================================

suggestPort :: Database -> Aff Response
suggestPort db = do
  rows <- queryAll db
    "SELECT port FROM project_servers WHERE port IS NOT NULL"
  let allocated = Array.sort (Array.catMaybes (map decodePort rows))
      free = firstGap 3000 allocated
      json = J.fromObject $ Object.fromFoldable
        [ "port" /\ J.fromNumber (Int.toNumber free) ]
  ok' jsonHeaders (J.stringify json)
  where
  decodePort :: Foreign -> Maybe Int
  decodePort f = case runExcept (readProp "port" f >>= readInt) of
    Left _ -> Nothing
    Right p -> Just p

  -- Walk the sorted allocated list finding the first gap starting from `start`.
  firstGap :: Int -> Array Int -> Int
  firstGap start xs = case Array.uncons xs of
    Nothing -> start
    Just { head, tail } ->
      if head < start then firstGap start tail
      else if head == start then firstGap (start + 1) tail
      else start

-- =============================================================================
-- Request body parsing (shared shape with API.Projects)
-- =============================================================================

parseBody :: String -> Maybe (FO.Object Json)
parseBody str = case jsonParser str of
  Left _ -> Nothing
  Right json -> J.toObject json

getStringField :: String -> FO.Object Json -> Maybe String
getStringField key obj = case FO.lookup key obj of
  Nothing -> Nothing
  Just j -> case J.toString j of
    Nothing -> Nothing
    Just "" -> Nothing
    Just s -> Just s

getIntField :: String -> FO.Object Json -> Maybe Int
getIntField key obj = case FO.lookup key obj of
  Nothing -> Nothing
  Just j -> case J.toNumber j of
    Nothing -> Nothing
    Just n -> Just (Int.floor n)
