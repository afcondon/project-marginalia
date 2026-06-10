-- | Engineering-spine API endpoints (goals / ADRs / coverage / provenance and
-- | their views), plus the realm extraction export.
-- |
-- | These are the read surface the dossier and Brunel query, the cross-project
-- | drift scan, the Tier-A migration export, and Brunel's one write (recording
-- | provenance). SQL construction here; JSON serialization via FFI (Spine.js),
-- | which marshals DuckDB's Foreign rows — handling BigINT integer columns —
-- | the same division of labour as API.Projects.
module API.Spine
  ( listGoals
  , listAdrs
  , listCoverage
  , listProvenance
  , listHealth
  , getDossier
  , listEngineeringProjects
  , listGoalHealth
  , listAdrOrphans
  , exportRealm
  , addProvenance
  ) where

import Prelude

import Data.Argonaut.Core (Json)
import Data.Argonaut.Core (toObject, toString) as J
import Data.Argonaut.Parser (jsonParser)
import Data.Either (Either(..))
import Data.Int as Int
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Nullable (toNullable)
import Database.DuckDB (Database, Rows, queryAll, queryAllParams, run)
import Effect.Aff (Aff)
import Foreign (unsafeToForeign)
import Foreign.Object (Object, lookup) as FO
import HTTPurple (Response, ok', badRequest')
import HTTPurple.Headers (ResponseHeaders, headers)

-- =============================================================================
-- FFI (Spine.js)
-- =============================================================================

foreign import rowsToJson :: Rows -> String
foreign import buildDossierJson :: Rows -> Rows -> Rows -> Rows -> Rows -> Rows -> String
foreign import buildExportJson :: String -> Rows -> Rows -> Rows -> Rows -> Rows -> String

-- =============================================================================
-- Per-project reads — the dossier surface
-- =============================================================================

listGoals :: Database -> Int -> Aff Response
listGoals db pid = do
  rows <- queryAllParams db
    "SELECT * FROM project_goals WHERE project_id = ? ORDER BY sort_order NULLS LAST, id"
    [ unsafeToForeign pid ]
  ok' jsonHeaders (rowsToJson rows)

listAdrs :: Database -> Int -> Aff Response
listAdrs db pid = do
  rows <- queryAllParams db
    "SELECT * FROM project_adrs WHERE project_id = ? ORDER BY number"
    [ unsafeToForeign pid ]
  ok' jsonHeaders (rowsToJson rows)

listCoverage :: Database -> Int -> Aff Response
listCoverage db pid = do
  rows <- queryAllParams db
    "SELECT * FROM coverage_snapshots WHERE project_id = ? ORDER BY taken_at DESC"
    [ unsafeToForeign pid ]
  ok' jsonHeaders (rowsToJson rows)

listProvenance :: Database -> Int -> Aff Response
listProvenance db pid = do
  rows <- queryAllParams db
    "SELECT * FROM provenance WHERE project_id = ? ORDER BY created_at DESC"
    [ unsafeToForeign pid ]
  ok' jsonHeaders (rowsToJson rows)

listHealth :: Database -> Int -> Aff Response
listHealth db pid = do
  rows <- queryAllParams db
    "SELECT * FROM goal_health WHERE project_id = ?"
    [ unsafeToForeign pid ]
  ok' jsonHeaders (rowsToJson rows)

-- | Composed per-project dossier: project + goals + ADRs + coverage +
-- | provenance + health, in one response. The press's primary read.
getDossier :: Database -> Int -> Aff Response
getDossier db pid = do
  let p = [ unsafeToForeign pid ]
  project    <- queryAllParams db "SELECT * FROM projects WHERE id = ?" p
  goals      <- queryAllParams db "SELECT * FROM project_goals WHERE project_id = ? ORDER BY sort_order NULLS LAST, id" p
  adrs       <- queryAllParams db "SELECT * FROM project_adrs WHERE project_id = ? ORDER BY number" p
  coverage   <- queryAllParams db "SELECT * FROM coverage_snapshots WHERE project_id = ? ORDER BY taken_at DESC" p
  provenance <- queryAllParams db "SELECT * FROM provenance WHERE project_id = ? ORDER BY created_at DESC" p
  health     <- queryAllParams db "SELECT * FROM goal_health WHERE project_id = ?" p
  ok' jsonHeaders (buildDossierJson project goals adrs coverage provenance health)

-- =============================================================================
-- Cross-project reads — Brunel / Humboldt
-- =============================================================================

listEngineeringProjects :: Database -> Aff Response
listEngineeringProjects db = do
  rows <- queryAll db "SELECT * FROM engineering_projects ORDER BY updated_at DESC NULLS LAST"
  ok' jsonHeaders (rowsToJson rows)

listGoalHealth :: Database -> Aff Response
listGoalHealth db = do
  rows <- queryAll db "SELECT * FROM goal_health ORDER BY last_evidence_at ASC NULLS FIRST"
  ok' jsonHeaders (rowsToJson rows)

listAdrOrphans :: Database -> Aff Response
listAdrOrphans db = do
  rows <- queryAll db "SELECT * FROM adr_orphans ORDER BY project_id, number"
  ok' jsonHeaders (rowsToJson rows)

-- =============================================================================
-- Tier A — realm extraction export
-- =============================================================================

-- | Dump a whole realm (its projects + dependent rows) as one re-importable
-- | bundle. The §12.5 migration reads `realm=life` from here.
exportRealm :: Database -> String -> Aff Response
exportRealm db realm = do
  let p = [ unsafeToForeign realm ]
  projects <- queryAllParams db
    "SELECT p.* FROM projects p JOIN domains d ON d.name = p.domain WHERE d.realm = ?" p
  notes <- queryAllParams db
    "SELECT n.* FROM project_notes n JOIN projects p ON p.id = n.project_id JOIN domains d ON d.name = p.domain WHERE d.realm = ?" p
  tags <- queryAllParams db
    "SELECT pt.project_id, t.name FROM project_tags pt JOIN tags t ON t.id = pt.tag_id JOIN projects p ON p.id = pt.project_id JOIN domains d ON d.name = p.domain WHERE d.realm = ?" p
  deps <- queryAllParams db
    "SELECT dep.* FROM dependencies dep JOIN projects p ON p.id = dep.blocker_id JOIN domains d ON d.name = p.domain WHERE d.realm = ?" p
  servers <- queryAllParams db
    "SELECT s.* FROM project_servers s JOIN projects p ON p.id = s.project_id JOIN domains d ON d.name = p.domain WHERE d.realm = ?" p
  ok' jsonHeaders (buildExportJson realm projects notes tags deps servers)

-- =============================================================================
-- C1 — Brunel records provenance (the one write in wave 1)
-- =============================================================================

-- | Insert a provenance edge: evidence that real work advances a goal or an
-- | ADR. Exactly one of goalId / adrId must be set (enforced here — the schema
-- | disables the FK per house convention, so integrity is app-side).
addProvenance :: Database -> Int -> String -> Aff Response
addProvenance db pid bodyStr = case parseBody bodyStr of
  Nothing -> badRequest' jsonHeaders """{"error":"Invalid JSON body"}"""
  Just obj ->
    let
      mRef  = getField "evidenceRef" obj
      kind  = fromMaybe "commit" (getField "evidenceKind" obj)
      mGoal = getField "goalId" obj >>= Int.fromString
      mAdr  = getField "adrId" obj >>= Int.fromString
      mNote = getField "note" obj
      author = fromMaybe "brunel" (getField "author" obj)
    in case mRef, mGoal, mAdr of
      Nothing, _, _ -> badRequest' jsonHeaders """{"error":"evidenceRef is required"}"""
      Just _, Just _, Just _ -> badRequest' jsonHeaders """{"error":"set exactly one of goalId / adrId, not both"}"""
      Just _, Nothing, Nothing -> badRequest' jsonHeaders """{"error":"set exactly one of goalId / adrId"}"""
      Just ref, _, _ -> do
        run db
          "INSERT INTO provenance (project_id, goal_id, adr_id, evidence_kind, evidence_ref, note, author) VALUES (?, ?, ?, ?, ?, ?, ?)"
          [ unsafeToForeign pid
          , unsafeToForeign (toNullable mGoal)
          , unsafeToForeign (toNullable mAdr)
          , unsafeToForeign kind
          , unsafeToForeign ref
          , unsafeToForeign (toNullable mNote)
          , unsafeToForeign author
          ]
        ok' jsonHeaders """{"ok":true}"""

-- =============================================================================
-- Local helpers (mirrored from API.Projects, which doesn't export them)
-- =============================================================================

jsonHeaders :: ResponseHeaders
jsonHeaders = headers
  { "Content-Type": "application/json"
  , "Access-Control-Allow-Origin": "*"
  }

parseBody :: String -> Maybe (FO.Object Json)
parseBody str = case jsonParser str of
  Left _ -> Nothing
  Right json -> J.toObject json

-- | Read a non-empty string field; treats "" as absent.
getField :: String -> FO.Object Json -> Maybe String
getField key obj = FO.lookup key obj >>= J.toString >>= \s ->
  if s == "" then Nothing else Just s
