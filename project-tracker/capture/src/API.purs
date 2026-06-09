-- | HTTP client for the Capture PWA.
-- |
-- | Thin wrapper around the Marginalia API, exposing only the endpoints the
-- | capture app needs. Always uses same-origin relative URLs — the frontend
-- | proxy (tools/frontend-server.mjs) routes /api/* to the API and /transcribe
-- | to the whisper sidecar.
module Capture.API
  ( fetchProjects
  , fetchActivity
  , fetchDossier
  , addNote
  , pickAndUploadPhoto
  , ProjectSummary
  , ActivitySummary
  , DossierNote
  , MobileDossier
  ) where

import Prelude

import Affjax.Web as AX
import Affjax.RequestBody as RequestBody
import Affjax.ResponseFormat as ResponseFormat
import Data.Argonaut.Core (Json, toObject, toArray, toString, toNumber) as J
import Data.Argonaut.Parser (jsonParser)
import Data.Either (Either(..))
import Data.Int (floor)
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Traversable (traverse)
import Control.Promise (Promise)
import Effect (Effect)
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
-- Activity feed (for the mobile Browse tab — projects sorted by recency score)
-- =============================================================================

-- | Slim activity row — just what the Browse mini-cards render.
type ActivitySummary =
  { id :: Int
  , name :: String
  , domain :: String
  , status :: String
  , score :: Number
  , description :: String
  }

fetchActivity :: Aff (Array ActivitySummary)
fetchActivity = do
  result <- AX.get ResponseFormat.string "/api/activity?limit=200"
  case result of
    Left _ -> pure []
    Right resp -> case jsonParser resp.body of
      Left _ -> pure []
      Right json -> pure (fromMaybe [] (decodeActivityList json))

decodeActivityList :: J.Json -> Maybe (Array ActivitySummary)
decodeActivityList json = do
  obj <- J.toObject json
  projsJson <- FO.lookup "projects" obj
  arr <- J.toArray projsJson
  traverse decodeActivityRow arr

decodeActivityRow :: J.Json -> Maybe ActivitySummary
decodeActivityRow json = do
  obj <- J.toObject json
  idJson <- FO.lookup "id" obj
  n <- J.toNumber idJson
  nameJson <- FO.lookup "name" obj
  name <- J.toString nameJson
  domainJson <- FO.lookup "domain" obj
  domain <- J.toString domainJson
  let status = fromMaybe "idea" (FO.lookup "status" obj >>= J.toString)
  let score = fromMaybe 0.0 (FO.lookup "score" obj >>= J.toNumber)
  let description = fromMaybe "" (FO.lookup "description" obj >>= J.toString)
  pure { id: floor n, name, domain, status, score, description }

-- =============================================================================
-- Dossier (single-project detail for the mobile read-only view)
-- =============================================================================

type DossierNote =
  { content :: String
  , author :: String
  , createdAt :: String
  }

type MobileDossier =
  { id :: Int
  , name :: String
  , domain :: String
  , status :: String
  , description :: String
  , notes :: Array DossierNote
  }

fetchDossier :: Int -> Aff (Maybe MobileDossier)
fetchDossier projectId = do
  result <- AX.get ResponseFormat.string ("/api/projects/" <> show projectId)
  case result of
    Left _ -> pure Nothing
    Right resp -> case jsonParser resp.body of
      Left _ -> pure Nothing
      Right json -> pure (decodeDossier json)

decodeDossier :: J.Json -> Maybe MobileDossier
decodeDossier json = do
  obj <- J.toObject json
  idJson <- FO.lookup "id" obj
  n <- J.toNumber idJson
  nameJson <- FO.lookup "name" obj
  name <- J.toString nameJson
  domainJson <- FO.lookup "domain" obj
  domain <- J.toString domainJson
  let status = fromMaybe "idea" (FO.lookup "status" obj >>= J.toString)
  let description = fromMaybe "" (FO.lookup "description" obj >>= J.toString)
  let notes = fromMaybe [] do
        notesJson <- FO.lookup "notes" obj
        arr <- J.toArray notesJson
        traverse decodeNote arr
  pure { id: floor n, name, domain, status, description, notes }

decodeNote :: J.Json -> Maybe DossierNote
decodeNote json = do
  obj <- J.toObject json
  contentJson <- FO.lookup "content" obj
  content <- J.toString contentJson
  let author = fromMaybe "unknown" (FO.lookup "author" obj >>= J.toString)
  let createdAt = fromMaybe "" (FO.lookup "createdAt" obj >>= J.toString)
  pure { content, author, createdAt }

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

-- =============================================================================
-- Upload a photo (camera capture or file picker)
-- =============================================================================

foreign import pickAndUploadPhotoImpl :: Int -> Effect (Promise String)

-- | Opens camera/file picker, uploads the selected photo, returns the
-- | filename on success or "" on cancel/failure.
pickAndUploadPhoto :: Int -> Effect (Promise String)
pickAndUploadPhoto = pickAndUploadPhotoImpl
