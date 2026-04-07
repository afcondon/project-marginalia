-- | NATO phonetic alphabet — designed for unambiguous voice communication.
-- |
-- | Each word was selected to be distinct from every other word, even in noisy
-- | conditions or with foreign accents. This is exactly the property we want
-- | for dictation-friendly identifiers.
module Slug.Nato (nato) where

import Prelude

nato :: Array String
nato =
  [ "alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel"
  , "india", "juliet", "kilo", "lima", "mike", "november", "oscar", "papa"
  , "quebec", "romeo", "sierra", "tango", "uniform", "victor", "whiskey"
  , "xray", "yankee", "zulu"
  ]
