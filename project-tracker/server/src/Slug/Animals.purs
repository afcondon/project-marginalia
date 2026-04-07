-- | Curated animal list for slug generation.
-- |
-- | Selection criteria:
-- |   - Common, recognizable animals
-- |   - Single-word names (no "polar bear" or "honey badger")
-- |   - Dictation-friendly (avoid homophones like "deer/dear", "bear/bare")
-- |   - Mix of mammals, birds, sea creatures, reptiles, insects
module Slug.Animals (animals) where

import Prelude

animals :: Array String
animals =
  -- Mammals: predators
  [ "wolf", "fox", "lynx", "cougar", "panther", "leopard", "tiger", "jaguar"
  , "ocelot", "cheetah", "lion", "wolverine", "weasel", "ferret", "marten"
  , "stoat", "mongoose", "civet", "fossa"

  -- Mammals: ungulates
  , "stag", "elk", "moose", "antelope", "ibex", "gazelle", "bison", "yak"
  , "tapir", "rhino", "zebra", "okapi", "giraffe", "buffalo", "gnu"

  -- Mammals: rodents and small
  , "otter", "badger", "beaver", "marmot", "lemur", "tarsier", "loris"
  , "pangolin", "armadillo", "hedgehog", "echidna", "platypus", "wombat"
  , "kangaroo", "wallaby", "koala", "possum", "raccoon", "coati", "kinkajou"

  -- Mammals: primates
  , "macaque", "gibbon", "orangutan", "mandrill", "baboon", "marmoset"
  , "capuchin", "tamarin", "colobus", "langur"

  -- Mammals: marine
  , "seal", "walrus", "dolphin", "porpoise", "narwhal", "beluga", "manatee"
  , "dugong", "orca"

  -- Birds: raptors
  , "hawk", "falcon", "kestrel", "harrier", "osprey", "goshawk", "kite"
  , "merlin", "condor", "vulture", "buzzard", "owl"

  -- Birds: songbirds
  , "wren", "robin", "finch", "sparrow", "warbler", "thrush", "lark"
  , "swallow", "martin", "bunting", "chickadee", "tanager", "oriole"
  , "starling", "nightingale", "blackbird", "magpie", "jay"

  -- Birds: water and shore
  , "heron", "egret", "stork", "ibis", "pelican", "cormorant", "puffin"
  , "tern", "petrel", "albatross", "gannet", "shearwater"

  -- Birds: game and large
  , "pheasant", "grouse", "quail", "partridge", "ptarmigan", "peacock"
  , "swan", "crane", "flamingo", "toucan", "hornbill", "parrot", "cockatoo"
  , "macaw", "parakeet", "lorikeet"

  -- Reptiles
  , "gecko", "iguana", "skink", "monitor", "chameleon", "anole", "python"
  , "viper", "cobra", "boa", "mamba", "krait", "tortoise", "terrapin"
  , "alligator", "crocodile", "caiman"

  -- Amphibians
  , "newt", "salamander", "axolotl", "toad", "tadpole"

  -- Sea creatures
  , "shark", "ray", "marlin", "tuna", "salmon", "trout", "perch", "carp"
  , "bass", "pike", "eel", "octopus", "squid", "cuttlefish", "nautilus"
  , "starfish", "urchin", "anemone", "jellyfish", "barnacle", "limpet"
  , "abalone", "mussel", "scallop", "lobster", "crayfish", "prawn", "krill"
  , "seahorse", "stingray", "manta"

  -- Insects and arthropods
  , "mantis", "cricket", "cicada", "firefly", "ladybug", "weevil", "beetle"
  , "moth", "butterfly", "dragonfly", "damselfly", "hornet", "wasp"
  , "scorpion", "tarantula", "centipede", "millipede"

  -- Misc
  , "cobra", "viper", "boa", "mole", "shrew", "vole", "lemming"
  , "chinchilla", "porcupine", "anteater", "sloth", "bandicoot"
  ]
