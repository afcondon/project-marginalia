-- | Exercise log API — powers the Sports section.
module API.Exercise
  ( listExercise
  , createExercise
  , monthlySummary
  ) where

import Prelude

import Data.Argonaut.Core (Json)
import Data.Argonaut.Core (toObject, toString) as J
import Data.Argonaut.Parser (jsonParser)
import Data.Either (Either(..))
import Data.Maybe (Maybe(..), fromMaybe)
import Database.DuckDB (Database, Rows, queryAll, queryAllParams, run, firstRow)
import Effect.Aff (Aff)
import Foreign (Foreign, unsafeToForeign)
import Foreign.Object as FO
import HTTPurple (Response, ok', badRequest')
import HTTPurple.Headers (ResponseHeaders, headers)

jsonHeaders :: ResponseHeaders
jsonHeaders = headers
  { "Content-Type": "application/json"
  , "Access-Control-Allow-Origin": "*"
  }

foreign import buildExerciseListJson :: Rows -> String
foreign import buildExerciseSummaryJson :: Rows -> String

getFieldMaybe :: String -> FO.Object Json -> Maybe String
getFieldMaybe key obj = case FO.lookup key obj of
  Nothing -> Nothing
  Just json -> case J.toString json of
    Nothing -> Nothing
    Just "" -> Nothing
    Just s -> Just s

getField :: String -> FO.Object Json -> String
getField key obj = fromMaybe "" (getFieldMaybe key obj)

parseBody :: String -> Maybe (FO.Object Json)
parseBody str = case jsonParser str of
  Left _ -> Nothing
  Right json -> J.toObject json

-- =============================================================================
-- GET /api/exercise
-- =============================================================================

listExercise :: Database -> Maybe String -> Aff Response
listExercise db mActivity = do
  let baseSql = "SELECT * FROM exercise_log WHERE 1=1"
  let actClause = case mActivity of
        Just _ -> " AND activity = ?"
        Nothing -> ""
  let sql = baseSql <> actClause <> " ORDER BY date DESC LIMIT 200"
  let params = case mActivity of
        Just a -> [unsafeToForeign a]
        Nothing -> []
  rows <- queryAllParams db sql params
  ok' jsonHeaders (buildExerciseListJson rows)

-- =============================================================================
-- POST /api/exercise
-- =============================================================================

createExercise :: Database -> String -> Aff Response
createExercise db bodyStr = case parseBody bodyStr of
  Nothing -> badRequest' jsonHeaders """{"error": "Invalid JSON body"}"""
  Just obj -> do
    let activity = fromMaybe "weights" (getFieldMaybe "activity" obj)
    let date = getField "date" obj
    let duration = getField "duration" obj
    let distance = getField "distance" obj
    let calories = getField "calories" obj
    let notes = getField "notes" obj
    let source = fromMaybe "manual" (getFieldMaybe "source" obj)
    run db
      """INSERT INTO exercise_log (activity, date, duration, distance, calories, notes, source)
         VALUES (?, ?, NULLIF(?, ''), NULLIF(?, ''), NULLIF(?, ''), NULLIF(?, ''), ?)"""
      [ unsafeToForeign activity, unsafeToForeign date
      , unsafeToForeign duration, unsafeToForeign distance
      , unsafeToForeign calories, unsafeToForeign notes
      , unsafeToForeign source ]
    rows <- queryAll db "SELECT * FROM exercise_log ORDER BY id DESC LIMIT 1"
    case firstRow rows of
      Nothing -> ok' jsonHeaders """{"error": "Insert failed"}"""
      Just row -> ok' jsonHeaders (buildExerciseListJson rows)

-- =============================================================================
-- GET /api/exercise/summary
-- =============================================================================

-- | Monthly summary: sessions per activity per month.
-- | Returns data shaped for the dot-block timeline.
monthlySummary :: Database -> Aff Response
monthlySummary db = do
  rows <- queryAll db
    """SELECT
         activity,
         EXTRACT(YEAR FROM date) AS year,
         EXTRACT(MONTH FROM date) AS month,
         COUNT(*) AS sessions,
         COALESCE(SUM(duration), 0) AS total_minutes
       FROM exercise_log
       WHERE date >= current_date - INTERVAL '12 months'
       GROUP BY activity, EXTRACT(YEAR FROM date), EXTRACT(MONTH FROM date)
       ORDER BY activity, year, month"""
  ok' jsonHeaders (buildExerciseSummaryJson rows)
