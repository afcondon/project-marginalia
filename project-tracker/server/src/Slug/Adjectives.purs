-- | Curated adjective list for slug generation.
-- |
-- | Selection criteria:
-- |   - Common, recognizable English words
-- |   - Dictation-friendly (no homophones, no near-duplicates)
-- |   - Evocative (color, light, texture, mood, motion, temperature)
-- |   - Avoid pejoratives and ambiguous terms
module Slug.Adjectives (adjectives) where

import Prelude

adjectives :: Array String
adjectives =
  -- Colors
  [ "amber", "azure", "scarlet", "crimson", "violet", "indigo", "emerald"
  , "jade", "ruby", "topaz", "ivory", "ebony", "saffron", "coral", "olive"
  , "sepia", "russet", "ochre", "maroon", "teal", "mauve", "fuchsia"
  , "cerulean", "vermilion", "turquoise", "umber", "magenta", "cobalt"

  -- Light and brightness
  , "bright", "dim", "luminous", "radiant", "glowing", "shimmering", "gleaming"
  , "pale", "vivid", "shining", "dazzling", "twinkling", "sparkling", "lustrous"
  , "brilliant", "shadowy", "dusky", "moonlit", "sunlit", "starlit"

  -- Texture
  , "silken", "velvet", "rough", "smooth", "rugged", "polished", "frosted"
  , "woven", "silvery", "golden", "bronze", "leathery", "glassy", "marble"
  , "feathery", "downy", "mossy", "dewy", "satin", "burnished"

  -- Sound
  , "silent", "quiet", "whispering", "roaring", "humming", "singing", "rustling"
  , "echoing", "thundering", "murmuring", "chiming", "muffled", "hushed"

  -- Motion
  , "swift", "gliding", "drifting", "soaring", "darting", "creeping", "racing"
  , "leaping", "wandering", "tumbling", "spinning", "still", "restless", "dancing"

  -- Temperature and weather
  , "frozen", "icy", "snowy", "frosty", "warm", "balmy", "sunny", "stormy"
  , "misty", "foggy", "rainy", "windy", "breezy", "glacial", "tropical"

  -- Mood and character
  , "gentle", "fierce", "merry", "solemn", "noble", "humble", "curious", "clever"
  , "wise", "brave", "calm", "lively", "patient", "quiet", "playful", "thoughtful"
  , "bold", "shy", "earnest", "serene", "spirited", "stoic", "valiant", "tender"

  -- Size and shape
  , "tall", "small", "vast", "tiny", "slender", "stout", "narrow", "broad"
  , "round", "angular", "compact", "sprawling", "looming", "petite", "lanky"

  -- Age and condition
  , "ancient", "young", "weathered", "fresh", "ripe", "antique", "novel", "timeless"
  , "rustic", "pristine", "worn", "burnished", "sturdy", "fragile", "vintage"

  -- Mystical and abstract
  , "hidden", "secret", "lost", "wild", "free", "lonely", "distant", "near"
  , "deep", "high", "low", "open", "closed", "first", "last", "true", "lucky"
  , "sacred", "mythic", "fabled", "rare", "common", "perfect", "humble", "regal"

  -- Nature
  , "wooded", "leafy", "rocky", "sandy", "stony", "grassy", "thorny", "blooming"
  , "fertile", "barren", "rugged", "mossy", "ferny", "rooted", "verdant", "lush"
  ]
