-- | The Infovore markdown ProjectSource.
-- |
-- | The marginalia server is the "press": it federates the tracker DuckDB
-- | (engineering realm) with a folder of frontmatter-markdown files in the
-- | infovore-larder-db repo (the personal "life" realm — woodworking / house /
-- | garden). This module is the bare reference `ProjectSource`: a folder of
-- | markdown, read straight off disk, surfaced into the project Register in the
-- | same JSON shape as DB-backed projects.
-- |
-- | All file reading, frontmatter parsing, filtering, dedupe and JSON building
-- | live in the FFI (Infovore.js) — legitimate FFI for filesystem + Foreign →
-- | JSON marshalling. This module just adapts `Maybe`/`Effect` to it.
module API.Infovore
  ( federatedListJson
  , detailJson
  ) where

import Prelude

import Data.Maybe (Maybe)
import Data.Nullable (Nullable, toMaybe, toNullable)
import Database.DuckDB (Rows)
import Effect (Effect)

foreign import federatedListJson_
  :: Rows
  -> Nullable String  -- domain filter
  -> Nullable String  -- status filter
  -> Nullable String  -- tag filter (present ⇒ life-projects suppressed)
  -> Nullable String  -- search text
  -> Effect String

foreign import detailJson_ :: Int -> Effect (Nullable String)

-- | Build the GET /api/projects payload, merging the already-filtered DB rows
-- | with the markdown life-projects (same filters re-applied, deduped by id).
federatedListJson
  :: Rows
  -> Maybe String -> Maybe String -> Maybe String -> Maybe String
  -> Effect String
federatedListJson rows mDomain mStatus mTag mSearch =
  federatedListJson_ rows
    (toNullable mDomain) (toNullable mStatus) (toNullable mTag) (toNullable mSearch)

-- | Detail for a life-project by (tracker) id — `Nothing` if no markdown file
-- | carries that id, so the caller can fall through to a 404.
detailJson :: Int -> Effect (Maybe String)
detailJson pid = map toMaybe (detailJson_ pid)
