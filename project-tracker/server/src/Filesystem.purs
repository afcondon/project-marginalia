-- | Filesystem operations for project rename/move.
-- |
-- | Most logic lives in the FFI; this module just exposes the high-level
-- | rename function with a typed result.
module Filesystem
  ( RenameOutcome(..)
  , renameProjectDirectory
  ) where

import Prelude

import Effect (Effect)
import Foreign (Foreign, unsafeFromForeign)

foreign import renameProjectDirectory_ :: String -> String -> Effect Foreign

-- | Result of attempting to rename a project's source directory.
data RenameOutcome
  = Skipped String          -- "skipped" — caller should still rename in DB. message has reason.
  | Renamed String String   -- "renamed" — newPath, method ("git mv" | "fs.rename")
  | RenameError String      -- "error"   — refuse to do anything

-- | Attempt to rename the directory at `sourcePath` to a slugified form of
-- | `newName` in the same parent directory. Uses `git mv` if inside a git
-- | repo, otherwise plain `fs.rename`. Refuses if the git working tree is
-- | dirty or the destination exists.
renameProjectDirectory :: String -> String -> Effect RenameOutcome
renameProjectDirectory sourcePath newName = do
  raw <- renameProjectDirectory_ sourcePath newName
  let r = unsafeFromForeign raw :: { kind :: String, reason :: String, newPath :: String, method :: String, error :: String }
  pure case r.kind of
    "skipped" -> Skipped r.reason
    "renamed" -> Renamed r.newPath r.method
    _ -> RenameError r.error
