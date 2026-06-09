-- | Blog draft storage — files on disk under $MARGINALIA_BLOG_DRAFTS.
-- |
-- | The file `<slug>.md` is the source of truth for a project's draft
-- | blog post. The browser UI shows a read-only preview; writes happen in
-- | VS Code via `openInVSCode` which shells out to `open -a`.
-- |
-- | Most logic lives in BlogDrafts.js; this module wraps the FFI with
-- | typed outcome ADTs (same pattern as Filesystem.purs).
module BlogDrafts
  ( EnsureOutcome(..)
  , OpenOutcome(..)
  , SaveAssetOutcome(..)
  , AssetInfo
  , MigrationSummary
  , readDraft
  , ensureDraft
  , openInVSCode
  , overrideBlogContent
  , migrateLegacyDrafts
  , saveBlogAsset
  , listBlogAssets
  ) where

import Prelude

import Data.Foldable (foldM)
import Data.Maybe (Maybe)
import Data.Nullable (Nullable, toMaybe, toNullable)
import Database.DuckDB (Database, queryAll, run)
import Effect (Effect)
import Effect.Aff (Aff)
import Effect.Class (liftEffect)
import Foreign (Foreign, unsafeFromForeign, unsafeToForeign)

-- =============================================================================
-- FFI imports
-- =============================================================================

foreign import readDraft_ :: String -> Effect (Nullable String)
foreign import ensureDraft_ :: String -> String -> Effect Foreign
foreign import writeDraftIfMissing_ :: String -> String -> Effect Foreign
foreign import openInVSCode_ :: String -> Effect Foreign
foreign import overrideBlogContent_ :: Foreign -> Nullable String -> Foreign
foreign import getRowString_ :: String -> Foreign -> String
foreign import saveBlogAsset_ :: String -> String -> String -> Effect Foreign
foreign import listBlogAssets_ :: String -> Effect (Array Foreign)

-- =============================================================================
-- Outcome ADTs
-- =============================================================================

-- | Result of ensuring a draft file exists.
data EnsureOutcome
  = EnsureOpened String   -- absolute path on disk, ready to spawn on
  | EnsureError String    -- I/O failure or invalid slug

-- | Result of shelling out to VS Code.
data OpenOutcome
  = OpenOk String         -- absolute path that was opened
  | OpenError String      -- spawn failed, or non-macOS

-- | Summary of the one-time startup migration.
type MigrationSummary =
  { written :: Int
  , skipped :: Int
  , errored :: Int
  }

-- =============================================================================
-- Public API
-- =============================================================================

-- | Read the draft file for the given slug. Returns Nothing if the file
-- | is missing, the slug is invalid, or the read fails — never throws.
readDraft :: String -> Effect (Maybe String)
readDraft slug = do
  n <- readDraft_ slug
  pure (toMaybe n)

-- | Ensure the draft file exists (create with a template if missing),
-- | returning its absolute path or an error message.
ensureDraft :: String -> String -> Effect EnsureOutcome
ensureDraft slug projectName = do
  raw <- ensureDraft_ slug projectName
  let r = unsafeFromForeign raw :: { kind :: String, absPath :: String, error :: String }
  pure case r.kind of
    "opened" -> EnsureOpened r.absPath
    _        -> EnsureError r.error

-- | Open an already-existing path in VS Code via `open -a`.
openInVSCode :: String -> Effect OpenOutcome
openInVSCode absPath = do
  raw <- openInVSCode_ absPath
  let r = unsafeFromForeign raw :: { kind :: String, absPath :: String, error :: String }
  pure case r.kind of
    "ok" -> OpenOk r.absPath
    _    -> OpenError r.error

-- | Mutate a project row in place so `buildProjectDetailJson` sees the
-- | file-sourced blog content instead of the DB column.
overrideBlogContent :: Foreign -> Maybe String -> Foreign
overrideBlogContent row mContent = overrideBlogContent_ row (toNullable mContent)

-- =============================================================================
-- Blog assets — images for embedding in drafts
-- =============================================================================

data SaveAssetOutcome
  = AssetSaved { filename :: String }
  | AssetError String

type AssetInfo = { filename :: String, size :: Int }

-- | Save a base64-encoded image to `<slug>/<filename>`.
saveBlogAsset :: String -> String -> String -> Effect SaveAssetOutcome
saveBlogAsset slug filename base64Data = do
  raw <- saveBlogAsset_ slug filename base64Data
  let r = unsafeFromForeign raw :: { kind :: String, filename :: String, absPath :: String, error :: String }
  pure case r.kind of
    "ok" -> AssetSaved { filename: r.filename }
    _    -> AssetError r.error

-- | List asset files in `<slug>/`.
listBlogAssets :: String -> Effect (Array AssetInfo)
listBlogAssets slug = do
  raws <- listBlogAssets_ slug
  pure (map (\raw -> unsafeFromForeign raw :: AssetInfo) raws)

-- =============================================================================
-- Startup migration
-- =============================================================================

-- | One-time migration: for every project row with non-null, non-empty
-- | `blog_content`, write `<slug>.md` if it doesn't already exist, then
-- | NULL out the DB column so subsequent startups find nothing to do.
-- |
-- | Idempotent: safe to run on every boot. After the first successful
-- | run, the WHERE clause returns zero rows and it's a no-op.
migrateLegacyDrafts :: Database -> Aff MigrationSummary
migrateLegacyDrafts db = do
  rows <- queryAll db
    """SELECT slug, blog_content
       FROM projects
       WHERE blog_content IS NOT NULL
         AND slug IS NOT NULL
         AND length(blog_content) > 0"""
  foldM migrateOne { written: 0, skipped: 0, errored: 0 } rows
  where
  migrateOne summary row = do
    let slug = getRowString_ "slug" row
    let content = getRowString_ "blog_content" row
    if slug == "" || content == ""
      then pure (summary { skipped = summary.skipped + 1 })
      else do
        raw <- liftEffect $ writeDraftIfMissing_ slug content
        let r = unsafeFromForeign raw :: { kind :: String, absPath :: String, error :: String }
        case r.kind of
          "written" -> do
            -- File written successfully. NULL the column so we never
            -- touch this row again and the DB doesn't keep a stale copy.
            run db
              "UPDATE projects SET blog_content = NULL WHERE slug = ?"
              [ unsafeToForeign slug ]
            pure (summary { written = summary.written + 1 })
          "skipped" -> do
            -- File already exists on disk — this row's DB value is stale.
            -- NULL it too so it matches the file-is-source-of-truth model.
            run db
              "UPDATE projects SET blog_content = NULL WHERE slug = ?"
              [ unsafeToForeign slug ]
            pure (summary { skipped = summary.skipped + 1 })
          _ ->
            pure (summary { errored = summary.errored + 1 })
