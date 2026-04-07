-- | Slug generation for project identifiers.
-- |
-- | Two styles supported:
-- |
-- |   * `NatoCallsign` — words from the NATO phonetic alphabet
-- |     (alpha-bravo-charlie-delta...). Designed for unambiguous voice
-- |     communication. Best choice for dictation. 26 words, so 4 words gives
-- |     ~457k combinations — collision probability negligible at our scale.
-- |
-- |   * `AdjAnimal` — adjective + N animals (amber-otter-finch). More evocative
-- |     and memorable visually, but Whisper occasionally garbles less common
-- |     animal names.
-- |
-- | Use `generateUniqueSlug` to retry against the database on collision.
module Slug
  ( SlugStyle(..)
  , defaultStyle
  , defaultWordCount
  , generateSlug
  , generateUniqueSlug
  ) where

import Prelude

import Data.Array as Array
import Data.Maybe (fromMaybe)
import Data.String as String
import Database.DuckDB (Database, queryAllParams, isEmpty)
import Effect (Effect)
import Effect.Aff (Aff)
import Effect.Class (liftEffect)
import Effect.Random (randomInt)
import Foreign (unsafeToForeign)
import Slug.Adjectives (adjectives)
import Slug.Animals (animals)
import Slug.Nato (nato)

data SlugStyle
  = NatoCallsign
  | AdjAnimal

derive instance Eq SlugStyle

-- | Default slug style: NATO callsigns are best for dictation.
defaultStyle :: SlugStyle
defaultStyle = NatoCallsign

-- | Default word count. NATO needs 4 for collision-free at our scale; AdjAnimal
-- | works fine at 3.
defaultWordCount :: Int
defaultWordCount = 4

-- | Generate a single slug. May collide with existing slugs.
generateSlug :: SlugStyle -> Int -> Effect String
generateSlug style wordCount = case style of
  NatoCallsign -> do
    parts <- pickN wordCount nato
    pure (String.joinWith "-" parts)
  AdjAnimal -> do
    adj <- pickRandom adjectives
    rest <- pickN (wordCount - 1) animals
    pure (String.joinWith "-" (Array.cons adj rest))

-- | Generate a slug guaranteed not to collide with any existing project.
-- | Retries up to 10 times before giving up.
generateUniqueSlug :: Database -> Aff String
generateUniqueSlug db = tryGenerate 10
  where
  tryGenerate :: Int -> Aff String
  tryGenerate attemptsLeft = do
    candidate <- liftEffect (generateSlug defaultStyle defaultWordCount)
    rows <- queryAllParams db
      "SELECT 1 FROM projects WHERE slug = ? LIMIT 1"
      [ unsafeToForeign candidate ]
    if isEmpty rows
      then pure candidate
      else if attemptsLeft <= 0
        then pure candidate
        else tryGenerate (attemptsLeft - 1)

-- | Pick N random elements from an array (with replacement).
pickN :: Int -> Array String -> Effect (Array String)
pickN n arr = go n []
  where
  go remaining acc
    | remaining <= 0 = pure acc
    | otherwise = do
        x <- pickRandom arr
        go (remaining - 1) (Array.snoc acc x)

-- | Pick a random element from an array. Returns empty string if array is empty.
pickRandom :: Array String -> Effect String
pickRandom arr = do
  let len = Array.length arr
  if len == 0
    then pure ""
    else do
      i <- randomInt 0 (len - 1)
      pure (fromMaybe "" (Array.index arr i))
