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
  , createGoal
  , updateGoal
  , createAdr
  , updateAdr
  , linkAdrGoal
  , unlinkAdrGoal
  ) where

import Prelude

import Data.Argonaut.Core (Json)
import Data.Argonaut.Core (toObject, toString) as J
import Data.Argonaut.Parser (jsonParser)
import Data.Array (elem, null) as Array
import Data.Either (Either(..))
import Data.Foldable (foldl)
import Data.Int as Int
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Nullable (toNullable)
import Data.String.Common (joinWith)
import Data.Tuple (Tuple(..))
import Database.DuckDB (Database, Rows, queryAll, queryAllParams, run)
import Effect.Aff (Aff)
import Foreign (Foreign, unsafeToForeign)
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
-- Wave 2 — Brunel's authoring surface (goals / ADRs / links)
-- =============================================================================

-- | Create a goal or non-goal. Returns the created row (via RETURNING).
createGoal :: Database -> Int -> String -> Aff Response
createGoal db pid bodyStr = case parseBody bodyStr of
  Nothing -> badRequest' jsonHeaders invalidJson
  Just obj -> case getField "text" obj of
    Nothing -> badRequest' jsonHeaders """{"error":"text is required"}"""
    Just text ->
      let kind = fromMaybe "goal" (getField "kind" obj)
      in
        if not (Array.elem kind [ "goal", "non_goal" ])
          then badRequest' jsonHeaders """{"error":"kind must be goal | non_goal"}"""
          else do
            rows <- queryAllParams db
              "INSERT INTO project_goals (project_id, kind, text, author, sort_order) VALUES (?, ?, ?, ?, ?) RETURNING *"
              [ unsafeToForeign pid
              , unsafeToForeign kind
              , unsafeToForeign text
              , unsafeToForeign (fromMaybe "brunel" (getField "author" obj))
              , unsafeToForeign (toNullable (getField "sortOrder" obj >>= Int.fromString))
              ]
            ok' jsonHeaders (rowsToJson rows)

-- | Transition a goal's status: active -> achieved | dropped (sets resolved_at
-- | + reason), or back to active (clears them).
updateGoal :: Database -> Int -> String -> Aff Response
updateGoal db goalId bodyStr = case parseBody bodyStr of
  Nothing -> badRequest' jsonHeaders invalidJson
  Just obj -> case getField "status" obj of
    Nothing -> badRequest' jsonHeaders """{"error":"status is required (active | achieved | dropped)"}"""
    Just "active" -> do
      rows <- queryAllParams db
        "UPDATE project_goals SET status = 'active', reason = NULL, resolved_at = NULL WHERE id = ? RETURNING *"
        [ unsafeToForeign goalId ]
      ok' jsonHeaders (rowsToJson rows)
    Just status | Array.elem status [ "achieved", "dropped" ] -> do
      rows <- queryAllParams db
        "UPDATE project_goals SET status = ?, reason = ?, resolved_at = current_timestamp WHERE id = ? RETURNING *"
        [ unsafeToForeign status
        , unsafeToForeign (toNullable (getField "reason" obj))
        , unsafeToForeign goalId
        ]
      ok' jsonHeaders (rowsToJson rows)
    Just _ -> badRequest' jsonHeaders """{"error":"status must be active | achieved | dropped"}"""

-- | Create an ADR. `number` is assigned app-side as MAX(number)+1 per project,
-- | computed in the INSERT … SELECT so it's one statement.
createAdr :: Database -> Int -> String -> Aff Response
createAdr db pid bodyStr = case parseBody bodyStr of
  Nothing -> badRequest' jsonHeaders invalidJson
  Just obj -> case getField "title" obj of
    Nothing -> badRequest' jsonHeaders """{"error":"title is required"}"""
    Just title ->
      let status = fromMaybe "proposed" (getField "status" obj)
      in
        if not (Array.elem status adrStatuses)
          then badRequest' jsonHeaders adrStatusError
          else do
            rows <- queryAllParams db
              ( "INSERT INTO project_adrs (project_id, number, title, status, context, decision, consequences, supersedes_id, author) "
                  <> "SELECT ?, COALESCE(MAX(number), 0) + 1, ?, ?, ?, ?, ?, ?, ? FROM project_adrs WHERE project_id = ? RETURNING *"
              )
              [ unsafeToForeign pid
              , unsafeToForeign title
              , unsafeToForeign status
              , unsafeToForeign (toNullable (getField "context" obj))
              , unsafeToForeign (toNullable (getField "decision" obj))
              , unsafeToForeign (toNullable (getField "consequences" obj))
              , unsafeToForeign (toNullable (getField "supersedesId" obj >>= Int.fromString))
              , unsafeToForeign (fromMaybe "brunel" (getField "author" obj))
              , unsafeToForeign pid
              ]
            ok' jsonHeaders (rowsToJson rows)

-- | Update an ADR's provided fields. Moving status off 'proposed' stamps
-- | decided_at. Status, if given, must be a valid Nygard state.
updateAdr :: Database -> Int -> String -> Aff Response
updateAdr db adrId bodyStr = case parseBody bodyStr of
  Nothing -> badRequest' jsonHeaders invalidJson
  Just obj ->
    let mStatus = getField "status" obj
    in case mStatus of
      Just s | not (Array.elem s adrStatuses) -> badRequest' jsonHeaders adrStatusError
      _ ->
        let
          base = buildStringUpdates
            [ Tuple "status" mStatus
            , Tuple "title" (getField "title" obj)
            , Tuple "context" (getField "context" obj)
            , Tuple "decision" (getField "decision" obj)
            , Tuple "consequences" (getField "consequences" obj)
            ]
          supersedes = case getField "supersedesId" obj >>= Int.fromString of
            Nothing -> { clauses: [], params: [] }
            Just sid -> { clauses: [ "supersedes_id = ?" ], params: [ unsafeToForeign sid ] }
          decided = case mStatus of
            Just s | s /= "proposed" -> [ "decided_at = current_timestamp" ]
            _ -> []
          clauses = base.clauses <> supersedes.clauses <> decided
          params = base.params <> supersedes.params <> [ unsafeToForeign adrId ]
        in
          if Array.null clauses then badRequest' jsonHeaders """{"error":"no fields to update"}"""
          else do
            rows <- queryAllParams db
              ("UPDATE project_adrs SET " <> joinWith ", " clauses <> " WHERE id = ? RETURNING *")
              params
            ok' jsonHeaders (rowsToJson rows)

-- | Link an ADR to a goal it pursues (idempotent).
linkAdrGoal :: Database -> String -> Aff Response
linkAdrGoal db bodyStr = case parseBody bodyStr of
  Nothing -> badRequest' jsonHeaders invalidJson
  Just obj -> case getField "adrId" obj >>= Int.fromString, getField "goalId" obj >>= Int.fromString of
    Just a, Just g -> do
      run db "INSERT INTO adr_goals (adr_id, goal_id) VALUES (?, ?) ON CONFLICT DO NOTHING"
        [ unsafeToForeign a, unsafeToForeign g ]
      ok' jsonHeaders """{"ok":true}"""
    _, _ -> badRequest' jsonHeaders """{"error":"adrId and goalId are required"}"""

-- | Remove an ADR↔goal link (ok whether or not it existed).
unlinkAdrGoal :: Database -> Int -> Int -> Aff Response
unlinkAdrGoal db adrId goalId = do
  run db "DELETE FROM adr_goals WHERE adr_id = ? AND goal_id = ?"
    [ unsafeToForeign adrId, unsafeToForeign goalId ]
  ok' jsonHeaders """{"ok":true}"""

-- =============================================================================
-- Local helpers (mirrored from API.Projects, which doesn't export them)
-- =============================================================================

invalidJson :: String
invalidJson = """{"error":"Invalid JSON body"}"""

adrStatuses :: Array String
adrStatuses = [ "proposed", "accepted", "rejected", "superseded", "deprecated" ]

adrStatusError :: String
adrStatusError = """{"error":"status must be proposed | accepted | rejected | superseded | deprecated"}"""

-- | Build "col = ?" SET clauses + matching params for the present string fields.
buildStringUpdates :: Array (Tuple String (Maybe String)) -> { clauses :: Array String, params :: Array Foreign }
buildStringUpdates = foldl step { clauses: [], params: [] }
  where
  step acc (Tuple col mv) = case mv of
    Nothing -> acc
    Just v -> { clauses: acc.clauses <> [ col <> " = ?" ], params: acc.params <> [ unsafeToForeign v ] }

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
