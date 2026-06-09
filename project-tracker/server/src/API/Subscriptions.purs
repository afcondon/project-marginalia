-- | Subscription CRUD — powers the Finance section of the newspaper.
-- |
-- | Tracks recurring payments, bills, and memberships. Surfaces
-- | "upcoming renewals" for the daily edition digest and "monthly burn"
-- | for the Finance section header.
module API.Subscriptions
  ( listSubscriptions
  , getSubscription
  , createSubscription
  , updateSubscription
  , deleteSubscription
  , upcomingSubscriptions
  ) where

import Prelude

import Data.Argonaut.Core (Json)
import Data.Argonaut.Core (toObject, toString, toNumber, toBoolean) as J
import Data.Argonaut.Parser (jsonParser)
import Data.Array as Array
import Data.Either (Either(..))
import Data.Int (floor) as Int
import Data.Maybe (Maybe(..), fromMaybe)
import Database.DuckDB (Database, Rows, queryAll, queryAllParams, run, firstRow, isEmpty)
import Effect.Aff (Aff)
import Foreign (Foreign, unsafeToForeign)
import Foreign.Object (Object, lookup) as FO
import HTTPurple (Response, ok', badRequest', notFound)
import HTTPurple.Headers (ResponseHeaders, headers)

jsonHeaders :: ResponseHeaders
jsonHeaders = headers
  { "Content-Type": "application/json"
  , "Access-Control-Allow-Origin": "*"
  }

-- =============================================================================
-- FFI (JSON response builders)
-- =============================================================================

foreign import buildSubscriptionListJson :: Rows -> String
foreign import buildSubscriptionDetailJson :: Foreign -> String

-- =============================================================================
-- JSON body parsing helpers
-- =============================================================================

getField :: String -> FO.Object Json -> String
getField key obj = case FO.lookup key obj of
  Nothing -> ""
  Just json -> fromMaybe "" (J.toString json)

getFieldMaybe :: String -> FO.Object Json -> Maybe String
getFieldMaybe key obj = case FO.lookup key obj of
  Nothing -> Nothing
  Just json -> case J.toString json of
    Nothing -> Nothing
    Just "" -> Nothing
    Just s -> Just s

getNumberField :: String -> FO.Object Json -> Maybe Number
getNumberField key obj = case FO.lookup key obj of
  Nothing -> Nothing
  Just json -> J.toNumber json

getBoolField :: String -> FO.Object Json -> Maybe Boolean
getBoolField key obj = case FO.lookup key obj of
  Nothing -> Nothing
  Just json -> J.toBoolean json

getIntField :: String -> FO.Object Json -> Maybe Int
getIntField key obj = case FO.lookup key obj of
  Nothing -> Nothing
  Just json -> case J.toNumber json of
    Just n -> Just (Int.floor n)
    Nothing -> Nothing

parseBody :: String -> Maybe (FO.Object Json)
parseBody str = case jsonParser str of
  Left _ -> Nothing
  Right json -> J.toObject json

-- =============================================================================
-- GET /api/subscriptions
-- =============================================================================

listSubscriptions :: Database -> Maybe String -> Aff Response
listSubscriptions db mCategory = do
  let baseSql = "SELECT * FROM subscriptions WHERE active = true"
  let catClause = case mCategory of
        Just _ -> " AND category = ?"
        Nothing -> ""
  let sql = baseSql <> catClause <> " ORDER BY next_due ASC NULLS LAST"
  let params = case mCategory of
        Just c -> [unsafeToForeign c]
        Nothing -> []
  rows <- queryAllParams db sql params
  ok' jsonHeaders (buildSubscriptionListJson rows)

-- =============================================================================
-- GET /api/subscriptions/upcoming?days=7
-- =============================================================================

upcomingSubscriptions :: Database -> String -> Aff Response
upcomingSubscriptions db daysStr = do
  rows <- queryAllParams db
    """SELECT * FROM subscriptions
       WHERE active = true
         AND next_due IS NOT NULL
         AND next_due <= current_date + CAST(? AS INTEGER)
       ORDER BY next_due ASC"""
    [unsafeToForeign daysStr]
  ok' jsonHeaders (buildSubscriptionListJson rows)

-- =============================================================================
-- GET /api/subscriptions/:id
-- =============================================================================

getSubscription :: Database -> Int -> Aff Response
getSubscription db subId = do
  rows <- queryAllParams db
    "SELECT * FROM subscriptions WHERE id = ?"
    [unsafeToForeign subId]
  case firstRow rows of
    Nothing -> notFound
    Just row -> ok' jsonHeaders (buildSubscriptionDetailJson row)

-- =============================================================================
-- POST /api/subscriptions
-- =============================================================================

createSubscription :: Database -> String -> Aff Response
createSubscription db bodyStr = case parseBody bodyStr of
  Nothing -> badRequest' jsonHeaders """{"error": "Invalid JSON body"}"""
  Just obj -> do
    let name = fromMaybe "Untitled" (getFieldMaybe "name" obj)
    let category = getField "category" obj
    let amount = getField "amount" obj
    let currency = fromMaybe "EUR" (getFieldMaybe "currency" obj)
    let frequency = fromMaybe "monthly" (getFieldMaybe "frequency" obj)
    let nextDue = getField "nextDue" obj
    let autoRenew = fromMaybe true (getBoolField "autoRenew" obj)
    let cancelUrl = getField "cancelUrl" obj
    let notes = getField "notes" obj
    let mProjectId = getIntField "projectId" obj

    case mProjectId of
      Nothing ->
        run db
          """INSERT INTO subscriptions (name, category, amount, currency, frequency,
             next_due, auto_renew, cancel_url, notes)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)"""
          [ unsafeToForeign name
          , unsafeToForeign category
          , unsafeToForeign amount
          , unsafeToForeign currency
          , unsafeToForeign frequency
          , unsafeToForeign nextDue
          , unsafeToForeign autoRenew
          , unsafeToForeign cancelUrl
          , unsafeToForeign notes
          ]
      Just projectId ->
        run db
          """INSERT INTO subscriptions (name, category, amount, currency, frequency,
             next_due, auto_renew, cancel_url, notes, project_id)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"""
          [ unsafeToForeign name
          , unsafeToForeign category
          , unsafeToForeign amount
          , unsafeToForeign currency
          , unsafeToForeign frequency
          , unsafeToForeign nextDue
          , unsafeToForeign autoRenew
          , unsafeToForeign cancelUrl
          , unsafeToForeign notes
          , unsafeToForeign projectId
          ]

    rows <- queryAll db "SELECT * FROM subscriptions ORDER BY id DESC LIMIT 1"
    case firstRow rows of
      Nothing -> ok' jsonHeaders """{"error": "Insert failed"}"""
      Just row -> ok' jsonHeaders (buildSubscriptionDetailJson row)

-- =============================================================================
-- PUT /api/subscriptions/:id
-- =============================================================================

updateSubscription :: Database -> Int -> String -> Aff Response
updateSubscription db subId bodyStr = case parseBody bodyStr of
  Nothing -> badRequest' jsonHeaders """{"error": "Invalid JSON body"}"""
  Just obj -> do
    let updates = buildUpdateClauses obj
    case updates.clauses of
      [] -> ok' jsonHeaders """{"error": "No fields to update"}"""
      _ -> do
        let setClauses = Array.intercalate ", " updates.clauses <> ", updated_at = current_timestamp"
        let sql = "UPDATE subscriptions SET " <> setClauses <> " WHERE id = ?"
        let params = updates.params <> [unsafeToForeign subId]
        run db sql params
        rows <- queryAllParams db "SELECT * FROM subscriptions WHERE id = ?" [unsafeToForeign subId]
        case firstRow rows of
          Nothing -> notFound
          Just row -> ok' jsonHeaders (buildSubscriptionDetailJson row)

type UpdateClauses = { clauses :: Array String, params :: Array Foreign }

buildUpdateClauses :: FO.Object Json -> UpdateClauses
buildUpdateClauses obj = { clauses, params }
  where
  fields =
    [ fieldClause "name" "name"
    , fieldClause "category" "category"
    , fieldClause "amount" "amount"
    , fieldClause "currency" "currency"
    , fieldClause "frequency" "frequency"
    , fieldClause "nextDue" "next_due"
    , fieldClause "cancelUrl" "cancel_url"
    , fieldClause "notes" "notes"
    , intFieldClause "projectId" "project_id"
    ]
  fieldClause :: String -> String -> Maybe { clause :: String, param :: Foreign }
  fieldClause jsonKey sqlCol = case getFieldMaybe jsonKey obj of
    Nothing -> Nothing
    Just val -> Just { clause: sqlCol <> " = ?", param: unsafeToForeign val }
  intFieldClause :: String -> String -> Maybe { clause :: String, param :: Foreign }
  intFieldClause jsonKey sqlCol = case getIntField jsonKey obj of
    Nothing -> Nothing
    Just n -> Just { clause: sqlCol <> " = ?", param: unsafeToForeign n }
  present = Array.catMaybes fields
  clauses = map _.clause present
  params = map _.param present

-- =============================================================================
-- DELETE /api/subscriptions/:id
-- =============================================================================

-- | Soft-delete: sets active = false rather than removing the row.
-- | Keeps history for "what did I used to pay for" analysis.
deleteSubscription :: Database -> Int -> Aff Response
deleteSubscription db subId = do
  run db
    "UPDATE subscriptions SET active = false, updated_at = current_timestamp WHERE id = ?"
    [unsafeToForeign subId]
  ok' jsonHeaders ("""{"id": """ <> show subId <> """, "active": false}""")
