-- | Shared domain types and JSON decoders for the Project Tracker frontend.
-- |
-- | Types mirror the API response shapes from the server. JSON decoding uses
-- | argonaut-codecs with manual decoders (not typeclass instances, per style guide).
module Types where

import Prelude

import Data.Argonaut.Core (Json, toObject, toArray, toString, toNumber, toBoolean)
import Data.Argonaut.Decode (JsonDecodeError(..))
import Data.Array as Array
import Data.Either (Either(..))
import Data.Generic.Rep (class Generic)
import Data.Int (floor)
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Show.Generic (genericShow)
import Data.Traversable (traverse)
import Foreign.Object as FO

-- =============================================================================
-- Status ADT
-- =============================================================================

data Status
  = Idea
  | Someday
  | Active
  | Dormant
  | Blocked
  | Done
  | Defunct
  | Evolved

derive instance Eq Status
derive instance Ord Status
derive instance Generic Status _
instance Show Status where
  show = genericShow

statusFromString :: String -> Maybe Status
statusFromString = case _ of
  "idea" -> Just Idea
  "someday" -> Just Someday
  "active" -> Just Active
  "dormant" -> Just Dormant
  "blocked" -> Just Blocked
  "done" -> Just Done
  "defunct" -> Just Defunct
  "evolved" -> Just Evolved
  _ -> Nothing

statusToString :: Status -> String
statusToString = case _ of
  Idea -> "idea"
  Someday -> "someday"
  Active -> "active"
  Dormant -> "dormant"
  Blocked -> "blocked"
  Done -> "done"
  Defunct -> "defunct"
  Evolved -> "evolved"

allStatuses :: Array Status
allStatuses = [ Idea, Someday, Active, Dormant, Blocked, Done, Defunct, Evolved ]

statusLabel :: Status -> String
statusLabel = case _ of
  Idea -> "Idea"
  Someday -> "Someday"
  Active -> "Active"
  Dormant -> "Dormant"
  Blocked -> "Blocked"
  Done -> "Done"
  Defunct -> "Defunct"
  Evolved -> "Evolved"

-- =============================================================================
-- BlogStatus — per-project blog post classification
-- =============================================================================
-- |
-- | A project's relationship with a future blog post. The NULL / Nothing
-- | case means the project has never been classified (initial state for
-- | everything until someone makes a decision about it). Content for
-- | drafted/published posts lives in a sibling `blogContent` field on
-- | `ProjectDetail`, not inside the constructor — the list view
-- | intentionally doesn't fetch content.

data BlogStatus
  = BlogNotNeeded
  | BlogWanted
  | BlogWantedPriority
  | BlogDrafted
  | BlogPublished

derive instance Eq BlogStatus
derive instance Ord BlogStatus
derive instance Generic BlogStatus _
instance Show BlogStatus where
  show = genericShow

blogStatusFromString :: String -> Maybe BlogStatus
blogStatusFromString = case _ of
  "not_needed"      -> Just BlogNotNeeded
  "wanted"          -> Just BlogWanted
  "wanted_priority" -> Just BlogWantedPriority
  "drafted"         -> Just BlogDrafted
  "published"       -> Just BlogPublished
  _                 -> Nothing

blogStatusToString :: BlogStatus -> String
blogStatusToString = case _ of
  BlogNotNeeded      -> "not_needed"
  BlogWanted         -> "wanted"
  BlogWantedPriority -> "wanted_priority"
  BlogDrafted        -> "drafted"
  BlogPublished      -> "published"

blogStatusLabel :: BlogStatus -> String
blogStatusLabel = case _ of
  BlogNotNeeded      -> "Not needed"
  BlogWanted         -> "Wanted"
  BlogWantedPriority -> "Priority"
  BlogDrafted        -> "Drafted"
  BlogPublished      -> "Published"

allBlogStatuses :: Array BlogStatus
allBlogStatuses = [ BlogNotNeeded, BlogWanted, BlogWantedPriority, BlogDrafted, BlogPublished ]

-- | Reachable next statuses for quick status transitions.
-- |
-- | Dormant is the "parked indefinitely" state — you're not actively moving
-- | the project forward, but you don't want to throw it away either. It's
-- | distinct from Someday (which implies positive intent to do later) and
-- | from Defunct (which implies abandonment). Reachable from any non-
-- | terminal state that isn't Done: an idea can be parked before it ever
-- | gets started, an active project can be paused, a blocker can turn
-- | into a long-term shelving decision. From Dormant you can resume
-- | (→ Active), revive interest without commitment (→ Someday), or
-- | acknowledge it's actually dead (→ Defunct).
-- |
-- | Evolved remains the one terminal state with no outgoing transitions.
nextStatuses :: Status -> Array Status
nextStatuses = case _ of
  Idea    -> [ Someday, Active, Dormant, Defunct ]
  Someday -> [ Active, Idea, Dormant, Defunct ]
  Active  -> [ Done, Dormant, Blocked, Defunct, Evolved ]
  Dormant -> [ Active, Someday, Defunct ]
  Blocked -> [ Active, Dormant, Defunct ]
  Done    -> [ Active ]
  Defunct -> [ Idea, Someday ]
  Evolved -> []

-- =============================================================================
-- Project (list item)
-- =============================================================================

type Project =
  { id :: Int
  , slug :: Maybe String
  , parentId :: Maybe Int
  , name :: String
  , domain :: String
  , subdomain :: Maybe String
  , status :: Status
  , description :: Maybe String
  , updatedAt :: Maybe String
  , tags :: Array String
  , coverUrl :: Maybe String
  , blogStatus :: Maybe BlogStatus
  , humanSummary :: Maybe String
  }

-- =============================================================================
-- ActivityRow (one row from GET /api/activity)
-- =============================================================================

-- | A ranked project from the activity endpoint. `score` blends recent notes,
-- | status transitions, and attachments with exponential-decay weighting; the
-- | component counts are carried alongside so the UI can show *why* a row
-- | ranked where it did, and so alternative heuristics can be trialled
-- | client-side without changing the server.
type ActivityRow =
  { id :: Int
  , slug :: Maybe String
  , name :: String
  , domain :: String
  , subdomain :: Maybe String
  , status :: Status
  , description :: Maybe String
  , score :: Number
  , notes7d :: Int
  , notes30d :: Int
  , notes90d :: Int
  , notesHuman30d :: Int
  , notesAgent30d :: Int
  , statusChanges30d :: Int
  , attachments30d :: Int
  , lastNoteAt :: Maybe String
  , lastStatusAt :: Maybe String
  , lastAttachmentAt :: Maybe String
  , lastActivityAt :: Maybe String
  , updatedAt :: Maybe String
  , pinned :: Boolean
  }

-- =============================================================================
-- ProjectDetail (single project with notes, deps, attachments)
-- =============================================================================

type Note =
  { id :: Int
  , content :: String
  , author :: Maybe String
  , createdAt :: Maybe String
  }

type DepRef =
  { projectId :: Int
  , projectName :: String
  , projectStatus :: String
  , dependencyType :: String
  }

type Dependencies =
  { blocking :: Array DepRef
  , blockedBy :: Array DepRef
  , related :: Array DepRef   -- symmetric "see also" cross-tree links
  }

type Attachment =
  { id :: Int
  , filename :: String
  , mimeType :: Maybe String
  , url :: Maybe String
  , description :: Maybe String
  , createdAt :: Maybe String
  }

-- =============================================================================
-- Server (port registry entry)
-- =============================================================================

type Server =
  { id :: Int
  , projectId :: Int
  , projectName :: String
  , projectSlug :: Maybe String
  , role :: String
  , port :: Maybe Int
  , url :: Maybe String
  , startCommand :: Maybe String
  , description :: Maybe String
  , environment :: Maybe String
  , prerequisites :: Maybe String
  }

type ProjectDetail =
  { id :: Int
  , slug :: Maybe String
  , parentId :: Maybe Int
  , name :: String
  , domain :: String
  , subdomain :: Maybe String
  , status :: Status
  , evolvedInto :: Maybe Int
  , description :: Maybe String
  , sourceUrl :: Maybe String
  , sourcePath :: Maybe String
  , repo :: Maybe String
  , preferredView :: Maybe String  -- "dossier" | "magazine" | Nothing for default
  , blogStatus :: Maybe BlogStatus
  , blogContent :: Maybe String
  , tags :: Array String
  , createdAt :: Maybe String
  , updatedAt :: Maybe String
  , notes :: Array Note
  , dependencies :: Dependencies
  , attachments :: Array Attachment
  }

-- =============================================================================
-- Stats
-- =============================================================================

type DomainStats =
  { domain :: String
  , total :: Int
  , statuses :: FO.Object Int
  }

type Stats =
  { totals ::
      { projects :: Int
      , tags :: Int
      , dependencies :: Int
      , notes :: Int
      }
  , domains :: Array String
  , byDomain :: Array DomainStats
  }

-- =============================================================================
-- ProjectInput (for create/update)
-- =============================================================================

type ProjectInput =
  { name :: String
  , domain :: String
  , subdomain :: String
  , status :: String
  , description :: String
  , repo :: String
  , sourceUrl :: String
  , sourcePath :: String
  , statusReason :: String
  , preferredView :: String   -- empty string means "don't update"
  , blogStatus :: String      -- empty string means "don't update"
  -- blogContent is no longer part of ProjectInput: drafts live on disk
  -- as files under $MARGINALIA_BLOG_DRAFTS and are written by VS Code
  -- directly. The browser only reads them via GET /api/projects/:id.
  }

-- =============================================================================
-- JSON Decoders (manual, not typeclass instances)
-- =============================================================================

-- Helper: get a field from a JSON object, returning Nothing if missing or null
getField :: String -> FO.Object Json -> Maybe Json
getField key obj = FO.lookup key obj

-- Helper: get a required string field
reqString :: String -> FO.Object Json -> Either JsonDecodeError String
reqString key obj = case getField key obj of
  Nothing -> Left (AtKey key MissingValue)
  Just j -> case toString j of
    Nothing -> Left (AtKey key (TypeMismatch "String"))
    Just s -> Right s

-- Helper: get an optional string field
optString :: String -> FO.Object Json -> Maybe String
optString key obj = case getField key obj of
  Nothing -> Nothing
  Just j -> toString j

-- Helper: get a required int field
reqInt :: String -> FO.Object Json -> Either JsonDecodeError Int
reqInt key obj = case getField key obj of
  Nothing -> Left (AtKey key MissingValue)
  Just j -> case toNumber j of
    Nothing -> Left (AtKey key (TypeMismatch "Number"))
    Just n -> Right (floor n)

-- Helper: get an optional int field
optInt :: String -> FO.Object Json -> Maybe Int
optInt key obj = case getField key obj of
  Nothing -> Nothing
  Just j -> case toNumber j of
    Nothing -> Nothing
    Just n -> Just (floor n)

-- Helper: decode a required Status field
reqStatus :: String -> FO.Object Json -> Either JsonDecodeError Status
reqStatus key obj = do
  s <- reqString key obj
  case statusFromString s of
    Nothing -> Left (AtKey key (TypeMismatch "Status"))
    Just st -> Right st

-- Helper: decode an optional BlogStatus field. Missing, null, or unrecognised
-- values all map to Nothing (which means "unclassified").
optBlogStatus :: String -> FO.Object Json -> Maybe BlogStatus
optBlogStatus key obj = do
  s <- optString key obj
  blogStatusFromString s

-- Helper: decode a string array field
decodeStringArray :: String -> FO.Object Json -> Array String
decodeStringArray key obj = case getField key obj of
  Nothing -> []
  Just j -> case toArray j of
    Nothing -> []
    Just arr -> Array.mapMaybe toString arr

decodeProject :: Json -> Either JsonDecodeError Project
decodeProject json = case toObject json of
  Nothing -> Left (TypeMismatch "Object")
  Just obj -> ado
    id <- reqInt "id" obj
    name <- reqString "name" obj
    domain <- reqString "domain" obj
    status <- reqStatus "status" obj
    in { id
       , slug: optString "slug" obj
       , parentId: optInt "parentId" obj
       , name
       , domain
       , subdomain: optString "subdomain" obj
       , status
       , description: optString "description" obj
       , updatedAt: optString "updatedAt" obj
       , tags: decodeStringArray "tags" obj
       , coverUrl: optString "coverUrl" obj
       , blogStatus: optBlogStatus "blogStatus" obj
       , humanSummary: optString "humanSummary" obj
       }

decodeProjectList :: Json -> Either JsonDecodeError (Array Project)
decodeProjectList json = case toObject json of
  Nothing -> Left (TypeMismatch "Object")
  Just obj -> case getField "projects" obj of
    Nothing -> Left (AtKey "projects" MissingValue)
    Just projsJson -> case toArray projsJson of
      Nothing -> Left (AtKey "projects" (TypeMismatch "Array"))
      Just arr -> traverse decodeProject arr

-- | Required Number field. Used for `score` on ActivityRow.
reqNumber :: String -> FO.Object Json -> Either JsonDecodeError Number
reqNumber key obj = case getField key obj of
  Nothing -> Left (AtKey key MissingValue)
  Just j -> case toNumber j of
    Nothing -> Left (AtKey key (TypeMismatch "Number"))
    Just n -> Right n

-- | Boolean field defaulting to false when missing / not-a-bool.
optBool :: String -> FO.Object Json -> Boolean
optBool key obj = case getField key obj of
  Nothing -> false
  Just j -> fromMaybe false (toBoolean j)

-- | Int field defaulting to 0 when missing. Used for the activity counts
-- | (they're always present in the server response, but defaulting to 0 keeps
-- | the decoder forgiving if a future server drops an unused count).
intOr0 :: String -> FO.Object Json -> Int
intOr0 key obj = case optInt key obj of
  Just n -> n
  Nothing -> 0

decodeActivityRow :: Json -> Either JsonDecodeError ActivityRow
decodeActivityRow json = case toObject json of
  Nothing -> Left (TypeMismatch "Object")
  Just obj -> ado
    id <- reqInt "id" obj
    name <- reqString "name" obj
    domain <- reqString "domain" obj
    status <- reqStatus "status" obj
    score <- reqNumber "score" obj
    in { id
       , slug: optString "slug" obj
       , name
       , domain
       , subdomain: optString "subdomain" obj
       , status
       , description: optString "description" obj
       , score
       , notes7d: intOr0 "notes7d" obj
       , notes30d: intOr0 "notes30d" obj
       , notes90d: intOr0 "notes90d" obj
       , notesHuman30d: intOr0 "notesHuman30d" obj
       , notesAgent30d: intOr0 "notesAgent30d" obj
       , statusChanges30d: intOr0 "statusChanges30d" obj
       , attachments30d: intOr0 "attachments30d" obj
       , lastNoteAt: optString "lastNoteAt" obj
       , lastStatusAt: optString "lastStatusAt" obj
       , lastAttachmentAt: optString "lastAttachmentAt" obj
       , lastActivityAt: optString "lastActivityAt" obj
       , updatedAt: optString "updatedAt" obj
       , pinned: optBool "pinned" obj
       }

decodeActivityList :: Json -> Either JsonDecodeError (Array ActivityRow)
decodeActivityList json = case toObject json of
  Nothing -> Left (TypeMismatch "Object")
  Just obj -> case getField "projects" obj of
    Nothing -> Left (AtKey "projects" MissingValue)
    Just projsJson -> case toArray projsJson of
      Nothing -> Left (AtKey "projects" (TypeMismatch "Array"))
      Just arr -> traverse decodeActivityRow arr

decodeNote :: Json -> Either JsonDecodeError Note
decodeNote json = case toObject json of
  Nothing -> Left (TypeMismatch "Object")
  Just obj -> ado
    id <- reqInt "id" obj
    content <- reqString "content" obj
    in { id
       , content
       , author: optString "author" obj
       , createdAt: optString "createdAt" obj
       }

decodeDepRef :: Json -> Either JsonDecodeError DepRef
decodeDepRef json = case toObject json of
  Nothing -> Left (TypeMismatch "Object")
  Just obj -> ado
    projectId <- reqInt "projectId" obj
    projectName <- reqString "projectName" obj
    projectStatus <- reqString "projectStatus" obj
    dependencyType <- reqString "dependencyType" obj
    in { projectId, projectName, projectStatus, dependencyType }

decodeAttachment :: Json -> Either JsonDecodeError Attachment
decodeAttachment json = case toObject json of
  Nothing -> Left (TypeMismatch "Object")
  Just obj -> ado
    id <- reqInt "id" obj
    filename <- reqString "filename" obj
    in { id
       , filename
       , mimeType: optString "mimeType" obj
       , url: optString "url" obj
       , description: optString "description" obj
       , createdAt: optString "createdAt" obj
       }

decodeServer :: Json -> Either JsonDecodeError Server
decodeServer json = case toObject json of
  Nothing -> Left (TypeMismatch "Object")
  Just obj -> ado
    id <- reqInt "id" obj
    projectId <- reqInt "projectId" obj
    projectName <- reqString "projectName" obj
    role <- reqString "role" obj
    in { id
       , projectId
       , projectName
       , projectSlug: optString "projectSlug" obj
       , role
       , port: optInt "port" obj
       , url: optString "url" obj
       , startCommand: optString "startCommand" obj
       , description: optString "description" obj
       , environment: optString "environment" obj
       , prerequisites: optString "prerequisites" obj
       }

-- | The /api/ports response envelope
decodeServerList :: Json -> Either JsonDecodeError (Array Server)
decodeServerList json = case toObject json of
  Nothing -> Left (TypeMismatch "Object")
  Just obj -> case getField "servers" obj of
    Nothing -> Left (AtKey "servers" MissingValue)
    Just serversJson -> case toArray serversJson of
      Nothing -> Left (AtKey "servers" (TypeMismatch "Array"))
      Just arr -> traverse decodeServer arr

-- | The /api/projects/:id/servers response is a bare array, not an envelope
decodeServerArray :: Json -> Either JsonDecodeError (Array Server)
decodeServerArray json = case toArray json of
  Nothing -> Left (TypeMismatch "Array")
  Just arr -> traverse decodeServer arr

-- | Decode an array field from a JSON object, using the given element decoder.
-- | Returns an empty array if the field is missing.
decodeArrayField :: forall a. String -> (Json -> Either JsonDecodeError a) -> FO.Object Json -> Either JsonDecodeError (Array a)
decodeArrayField key decoder obj = case getField key obj of
  Nothing -> Right []
  Just j -> case toArray j of
    Nothing -> Left (AtKey key (TypeMismatch "Array"))
    Just arr -> traverse decoder arr

decodeDependencies :: Json -> Either JsonDecodeError Dependencies
decodeDependencies json = case toObject json of
  Nothing -> Left (TypeMismatch "Object")
  Just obj -> ado
    blocking <- decodeArrayField "blocking" decodeDepRef obj
    blockedBy <- decodeArrayField "blockedBy" decodeDepRef obj
    related <- decodeArrayField "related" decodeDepRef obj
    in { blocking, blockedBy, related }

decodeProjectDetail :: Json -> Either JsonDecodeError ProjectDetail
decodeProjectDetail json = case toObject json of
  Nothing -> Left (TypeMismatch "Object")
  Just obj -> ado
    id <- reqInt "id" obj
    name <- reqString "name" obj
    domain <- reqString "domain" obj
    status <- reqStatus "status" obj
    notes <- decodeArrayField "notes" decodeNote obj
    dependencies <- case getField "dependencies" obj of
      Nothing -> Right { blocking: [], blockedBy: [], related: [] }
      Just depsJson -> decodeDependencies depsJson
    attachments <- decodeArrayField "attachments" decodeAttachment obj
    in { id
       , slug: optString "slug" obj
       , parentId: optInt "parentId" obj
       , name
       , domain
       , subdomain: optString "subdomain" obj
       , status
       , evolvedInto: optInt "evolvedInto" obj
       , description: optString "description" obj
       , sourceUrl: optString "sourceUrl" obj
       , sourcePath: optString "sourcePath" obj
       , repo: optString "repo" obj
       , preferredView: optString "preferredView" obj
       , blogStatus: optBlogStatus "blogStatus" obj
       , blogContent: optString "blogContent" obj
       , tags: decodeStringArray "tags" obj
       , createdAt: optString "createdAt" obj
       , updatedAt: optString "updatedAt" obj
       , notes
       , dependencies
       , attachments
       }

decodeDomainStats :: Json -> Either JsonDecodeError DomainStats
decodeDomainStats json = case toObject json of
  Nothing -> Left (TypeMismatch "Object")
  Just obj -> ado
    domain <- reqString "domain" obj
    total <- reqInt "total" obj
    in { domain
       , total
       , statuses: decodeIntObject "statuses" obj
       }
  where
  decodeIntObject key obj = case getField key obj of
    Nothing -> FO.empty
    Just j -> case toObject j of
      Nothing -> FO.empty
      Just inner -> FO.mapWithKey (\_ v -> fromMaybe 0 (map floor (toNumber v))) inner

decodeStats :: Json -> Either JsonDecodeError Stats
decodeStats json = case toObject json of
  Nothing -> Left (TypeMismatch "Object")
  Just obj -> ado
    totals <- decodeTotals obj
    domains <- decodeStrArrayField "domains" obj
    byDomain <- decodeArrayField "byDomain" decodeDomainStats obj
    in { totals, domains, byDomain }
  where
  decodeTotals obj = case getField "totals" obj of
    Nothing -> Left (AtKey "totals" MissingValue)
    Just j -> case toObject j of
      Nothing -> Left (AtKey "totals" (TypeMismatch "Object"))
      Just tObj -> ado
        projects <- reqInt "projects" tObj
        tags <- reqInt "tags" tObj
        dependencies <- reqInt "dependencies" tObj
        notes <- reqInt "notes" tObj
        in { projects, tags, dependencies, notes }

  decodeStrArrayField key obj = case getField key obj of
    Nothing -> Right []
    Just j -> case toArray j of
      Nothing -> Left (AtKey key (TypeMismatch "Array"))
      Just arr -> Right (Array.mapMaybe toString arr)
