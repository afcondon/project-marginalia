-- | HTTP client for the Capture PWA.
-- |
-- | Thin wrapper around the Marginalia API, exposing only the endpoints the
-- | capture app needs. Always uses same-origin relative URLs — the frontend
-- | proxy (tools/frontend-server.mjs) routes /api/* to the API and /transcribe
-- | to the whisper sidecar.
module Capture.API
  ( fetchProjects
  , addNote
  , ProjectSummary
  ) where

import Prelude

import Affjax.Web as AX
import Affjax.RequestBody as RequestBody
import Affjax.ResponseFormat as ResponseFormat
import Data.Argonaut.Core (Json, toObject, toArray, toString, toNumber) as J
import Data.Argonaut.Parser (jsonParser)
import Data.Array as Array
import Data.Either (Either(..))
import Data.Int (floor)
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Traversable (traverse)
import Effect.Aff (Aff)
import Foreign.Object as FO

-- | Compact project info — just enough for the project picker. We don't
-- | need the full Project record from Types.purs here; keeping a slimmer
-- | type avoids importing the desktop frontend's module.
type ProjectSummary =
  { id :: Int
  , name :: String
  , domain :: String
  , status :: String
  }

-- =============================================================================
-- Fetch projects (for the picker)
-- =============================================================================

fetchProjects :: Aff (Array ProjectSummary)
fetchProjects = do
  result <- AX.get ResponseFormat.string "/api/projects"
  case result of
    Left _ -> pure []
    Right resp -> case jsonParser resp.body of
      Left _ -> pure []
      Right json -> case decodeProjectList json of
        Nothing -> pure []
        Just ps -> pure ps

decodeProjectList :: J.Json -> Maybe (Array ProjectSummary)
decodeProjectList json = do
  obj <- J.toObject json
  projsJson <- FO.lookup "projects" obj
  arr <- J.toArray projsJson
  traverse decodeProjectSummary arr

decodeProjectSummary :: J.Json -> Maybe ProjectSummary
decodeProjectSummary json = do
  obj <- J.toObject json
  idJson <- FO.lookup "id" obj
  n <- J.toNumber idJson
  nameJson <- FO.lookup "name" obj
  name <- J.toString nameJson
  domainJson <- FO.lookup "domain" obj
  domain <- J.toString domainJson
  let status = fromMaybe "idea" (FO.lookup "status" obj >>= J.toString)
  pure { id: floor n, name, domain, status }

-- =============================================================================
-- Add a note (voice transcript, typed text, or URL)
-- =============================================================================

addNote :: Int -> String -> Aff Boolean
addNote projectId content = do
  let body = """{"content":""" <> quote content <> ""","author":"capture"}"""
  result <- AX.post ResponseFormat.string ("/api/agent/projects/" <> show projectId <> "/notes")
    (Just (RequestBody.string body))
  pure (isRight result)
  where
  isRight (Right _) = true
  isRight _ = false

-- Minimal JSON string escaping — good enough for note content.
-- Handles the characters that would break the JSON envelope.
quote :: String -> String
quote s = "\"" <> escapeJson s <> "\""

foreign import escapeJson :: String -> String
