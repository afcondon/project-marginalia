-- | HTTP client for the Project Tracker API.
-- |
-- | Uses affjax-web to communicate with the HTTPurple server on port 3100.
-- | All functions return Aff and handle JSON decoding via the decoders in Types.
module API
  ( fetchProjects
  , fetchProject
  , fetchStats
  , createProject
  , createChild
  , updateProject
  , renameProject
  , addNote
  ) where

import Prelude

import Affjax.Web as AX
import Affjax.RequestBody as RequestBody
import Affjax.ResponseFormat as ResponseFormat
import Data.Argonaut.Core (toObject, toString) as J
import Data.Argonaut.Parser (jsonParser)
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Effect.Aff (Aff)
import Effect.Class (liftEffect)
import Effect.Console (log)
import Foreign.Object (lookup) as FO
import Types (Project, ProjectDetail, ProjectInput, Stats, decodeProjectList, decodeProjectDetail, decodeStats)

-- =============================================================================
-- Configuration
-- =============================================================================

baseUrl :: String
baseUrl = "http://localhost:3100"

-- =============================================================================
-- Helpers
-- =============================================================================

-- | Build a query string from optional parameters.
-- | Only includes parameters that have a value.
buildQueryString :: Maybe String -> Maybe String -> Maybe String -> Maybe Int -> Maybe String -> String
buildQueryString mDomain mStatus mTag mAncestor mSearch =
  let params = domainP <> statusP <> tagP <> ancestorP <> searchP
      domainP = case mDomain of
        Just d -> [ "domain=" <> d ]
        Nothing -> []
      statusP = case mStatus of
        Just s -> [ "status=" <> s ]
        Nothing -> []
      tagP = case mTag of
        Just t -> [ "tag=" <> t ]
        Nothing -> []
      ancestorP = case mAncestor of
        Just a -> [ "ancestor=" <> show a ]
        Nothing -> []
      searchP = case mSearch of
        Just q -> [ "search=" <> q ]
        Nothing -> []
  in case params of
    [] -> ""
    _ -> "?" <> joinWith "&" params
  where
  joinWith sep arr = case arr of
    [] -> ""
    _ -> foldlWithSep sep arr

-- Manual join since Data.String.joinWith needs an import
foldlWithSep :: String -> Array String -> String
foldlWithSep sep arr = case arr of
  [] -> ""
  _  -> go 0 ""
  where
  len = arrayLength arr
  go i acc
    | i >= len = acc
    | i == 0 = go 1 (unsafeIndex arr 0)
    | otherwise = go (i + 1) (acc <> sep <> unsafeIndex arr i)

foreign import arrayLength :: forall a. Array a -> Int
foreign import unsafeIndex :: forall a. Array a -> Int -> a

-- =============================================================================
-- API Functions
-- =============================================================================

-- | Fetch the project list, with optional filters for domain, status, tag, ancestor, and search text.
fetchProjects :: Maybe String -> Maybe String -> Maybe String -> Maybe Int -> Maybe String -> Aff (Array Project)
fetchProjects mDomain mStatus mTag mAncestor mSearch = do
  let url = baseUrl <> "/api/projects" <> buildQueryString mDomain mStatus mTag mAncestor mSearch
  result <- AX.get ResponseFormat.string url
  case result of
    Left err -> do
      liftEffect $ log $ "fetchProjects error: " <> AX.printError err
      pure []
    Right response -> case jsonParser response.body of
      Left _ -> do
        liftEffect $ log "fetchProjects: failed to parse JSON"
        pure []
      Right json -> case decodeProjectList json of
        Left decErr -> do
          liftEffect $ log $ "fetchProjects: decode error: " <> show decErr
          pure []
        Right projects -> pure projects

-- | Fetch a single project by ID, including notes, dependencies, and attachments.
fetchProject :: Int -> Aff (Maybe ProjectDetail)
fetchProject projectId = do
  let url = baseUrl <> "/api/projects/" <> show projectId
  result <- AX.get ResponseFormat.string url
  case result of
    Left err -> do
      liftEffect $ log $ "fetchProject error: " <> AX.printError err
      pure Nothing
    Right response -> case jsonParser response.body of
      Left _ -> do
        liftEffect $ log "fetchProject: failed to parse JSON"
        pure Nothing
      Right json -> case decodeProjectDetail json of
        Left decErr -> do
          liftEffect $ log $ "fetchProject: decode error: " <> show decErr
          pure Nothing
        Right detail -> pure (Just detail)

-- | Fetch aggregate statistics (totals, domain/status breakdown).
fetchStats :: Aff (Maybe Stats)
fetchStats = do
  let url = baseUrl <> "/api/stats"
  result <- AX.get ResponseFormat.string url
  case result of
    Left err -> do
      liftEffect $ log $ "fetchStats error: " <> AX.printError err
      pure Nothing
    Right response -> case jsonParser response.body of
      Left _ -> do
        liftEffect $ log "fetchStats: failed to parse JSON"
        pure Nothing
      Right json -> case decodeStats json of
        Left decErr -> do
          liftEffect $ log $ "fetchStats: decode error: " <> show decErr
          pure Nothing
        Right stats -> pure (Just stats)

-- | Create a new project. Returns the created project on success.
createProject :: ProjectInput -> Aff (Maybe Project)
createProject input = do
  let url = baseUrl <> "/api/projects"
  let body = buildCreateBody input
  result <- AX.post ResponseFormat.string url (Just (RequestBody.string body))
  case result of
    Left err -> do
      liftEffect $ log $ "createProject error: " <> AX.printError err
      pure Nothing
    Right response -> case jsonParser response.body of
      Left _ -> do
        liftEffect $ log "createProject: failed to parse JSON"
        pure Nothing
      Right json -> case decodeProjectList json of
        Left decErr -> do
          liftEffect $ log $ "createProject: decode error: " <> show decErr
          pure Nothing
        Right projects -> case projects of
          [] -> pure Nothing
          _  -> pure (Just (unsafeIndex projects 0))

-- | Update an existing project. Returns the updated project on success.
updateProject :: Int -> ProjectInput -> Aff (Maybe Project)
updateProject projectId input = do
  let url = baseUrl <> "/api/projects/" <> show projectId
  let body = buildUpdateBody input
  result <- AX.put ResponseFormat.string url (Just (RequestBody.string body))
  case result of
    Left err -> do
      liftEffect $ log $ "updateProject error: " <> AX.printError err
      pure Nothing
    Right response -> case jsonParser response.body of
      Left _ -> do
        liftEffect $ log "updateProject: failed to parse JSON"
        pure Nothing
      Right json -> case decodeProjectList json of
        Left decErr -> do
          liftEffect $ log $ "updateProject: decode error: " <> show decErr
          pure Nothing
        Right projects -> case projects of
          [] -> pure Nothing
          _  -> pure (Just (unsafeIndex projects 0))

-- | Add a note to a project via the agent API.
addNote :: Int -> String -> Aff Unit
addNote projectId content = do
  let url = baseUrl <> "/api/agent/projects/" <> show projectId <> "/notes"
  let body = buildNoteBody content
  _ <- AX.post ResponseFormat.string url (Just (RequestBody.string body))
  pure unit

-- | Result of a rename attempt — used to surface warnings/errors to the UI.
type RenameResponse =
  { ok :: Boolean
  , message :: Maybe String  -- error text on failure, or warning on partial success
  }

-- | Rename a project, optionally also renaming its source directory.
-- | Returns Ok with an optional warning, or an error message.
renameProject :: Int -> String -> Boolean -> Aff RenameResponse
renameProject projectId newName renameDir = do
  let url = baseUrl <> "/api/projects/" <> show projectId <> "/rename"
  let body = buildRenameBody newName renameDir
  result <- AX.post ResponseFormat.string url (Just (RequestBody.string body))
  case result of
    Left err -> pure { ok: false, message: Just (AX.printError err) }
    Right response -> case jsonParser response.body of
      Left _ -> pure { ok: false, message: Just "failed to parse response" }
      Right json -> case J.toObject json of
        Nothing -> pure { ok: false, message: Just "response was not an object" }
        Just obj -> do
          let mError = J.toString =<< FO.lookup "error" obj
          let mWarning = J.toString =<< FO.lookup "warning" obj
          case mError of
            Just e -> pure { ok: false, message: Just e }
            Nothing -> pure { ok: true, message: mWarning }

-- | Create a child project under the given parent. Returns the new project on success.
createChild :: Int -> String -> String -> Aff (Maybe Project)
createChild parentId name domain = do
  let url = baseUrl <> "/api/projects"
  let body = buildChildBody parentId name domain
  result <- AX.post ResponseFormat.string url (Just (RequestBody.string body))
  case result of
    Left _ -> pure Nothing
    Right response -> case jsonParser response.body of
      Left _ -> pure Nothing
      Right json -> case decodeProjectList json of
        Left _ -> pure Nothing
        Right projects -> case projects of
          [] -> pure Nothing
          _ -> pure (Just (unsafeIndex projects 0))

-- =============================================================================
-- JSON Body Builders (FFI)
-- =============================================================================

foreign import buildCreateBody :: ProjectInput -> String
foreign import buildUpdateBody :: ProjectInput -> String
foreign import buildNoteBody :: String -> String
foreign import buildChildBody :: Int -> String -> String -> String
foreign import buildRenameBody :: String -> Boolean -> String
