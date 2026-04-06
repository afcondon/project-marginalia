-- | Entry point for the Project Tracker frontend.
-- | Mounts the Halogen application to the #app element.
module ProjectTracker.Main where

import Prelude

import Component.App as App
import Data.Maybe (Maybe(..))
import Effect.Class (liftEffect)
import Effect (Effect)
import Effect.Exception (throw)
import Halogen.Aff (awaitLoad, selectElement, runHalogenAff)
import Halogen.VDom.Driver (runUI)
import Web.DOM.ParentNode (QuerySelector(..))

main :: Effect Unit
main = runHalogenAff do
  awaitLoad
  mEl <- selectElement (QuerySelector "#app")
  case mEl of
    Nothing -> liftEffect $ throw "Could not find #app element"
    Just el -> void $ runUI App.component unit el
