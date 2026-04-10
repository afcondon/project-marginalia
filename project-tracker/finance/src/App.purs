-- | Finance visualization — sparkline timeline + cost breakdown.
-- |
-- | Fetches subscriptions from the API and renders:
-- |   - A timeline with one row per subscription (name, sparkline, amount)
-- |   - RHS summary column (daily/monthly/yearly totals)
-- |   - Bottom total bar
-- |
-- | Sparklines are pure SVG rendered via Halogen. Each subscription gets
-- | a 12-month horizontal bar where the height represents charge months
-- | and the color comes from the category.
module Finance.App where

import Prelude

import Affjax.Web as AX
import Affjax.ResponseFormat as ResponseFormat
import Data.Array as Array
import Data.Either (Either(..))
import Data.Int (toNumber)
import Data.Maybe (Maybe(..))
import Data.Number.Format (toStringWith, fixed)
import Effect.Aff.Class (class MonadAff, liftAff)
import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Properties as HP
import Halogen.Svg.Elements as SE
import Halogen.Svg.Attributes as SA

-- =============================================================================
-- FFI
-- =============================================================================

foreign import parseSubscriptions_ :: String -> SubscriptionData

type Sub =
  { id :: Int
  , name :: String
  , category :: String
  , amount :: Number
  , currency :: String
  , frequency :: String
  , nextDue :: String
  , notes :: String
  }

type SubscriptionData =
  { subscriptions :: Array Sub
  , monthlyBurn :: Number
  }

-- =============================================================================
-- Types
-- =============================================================================

type State =
  { subs :: Array Sub
  , monthlyBurn :: Number
  , loading :: Boolean
  }

data Action = Initialize

-- =============================================================================
-- Component
-- =============================================================================

component :: forall q i o m. MonadAff m => H.Component q i o m
component = H.mkComponent
  { initialState: \_ -> { subs: [], monthlyBurn: 0.0, loading: true }
  , render
  , eval: H.mkEval $ H.defaultEval
      { handleAction = handleAction
      , initialize = Just Initialize
      }
  }

handleAction :: forall o m. MonadAff m =>
  Action -> H.HalogenM State Action () o m Unit
handleAction = case _ of
  Initialize -> do
    result <- liftAff $ AX.get ResponseFormat.string "/api/subscriptions"
    case result of
      Left _ -> H.modify_ \s -> s { loading = false }
      Right resp -> do
        let d = parseSubscriptions_ resp.body
        H.modify_ \s -> s { subs = d.subscriptions, monthlyBurn = d.monthlyBurn, loading = false }

-- =============================================================================
-- Render
-- =============================================================================

render :: forall m. State -> H.ComponentHTML Action () m
render state =
  HH.div [ HP.class_ (H.ClassName "finance-app") ]
    [ renderMasthead
    , if state.loading
        then HH.div [ HP.class_ (H.ClassName "finance-loading") ] [ HH.text "Loading..." ]
        else HH.div [ HP.class_ (H.ClassName "finance-layout") ]
          [ HH.div [ HP.class_ (H.ClassName "timeline-area") ]
              [ renderTimelineHeader
              , HH.div_ (map renderSubRow state.subs)
              , renderFooter state
              ]
          , renderSummary state
          ]
    ]

renderMasthead :: forall m. H.ComponentHTML Action () m
renderMasthead =
  HH.div [ HP.class_ (H.ClassName "finance-masthead") ]
    [ HH.h1 [ HP.class_ (H.ClassName "finance-title") ] [ HH.text "Finance" ]
    , HH.span [ HP.class_ (H.ClassName "finance-subtitle") ]
        [ HH.text "The Cambrian Explosion" ]
    ]

renderTimelineHeader :: forall m. H.ComponentHTML Action () m
renderTimelineHeader =
  HH.div [ HP.class_ (H.ClassName "timeline-header") ]
    [ HH.span [ HP.class_ (H.ClassName "timeline-label") ] [ HH.text "Subscription" ]
    , HH.span [ HP.class_ (H.ClassName "timeline-label") ] [ HH.text "12-month pattern" ]
    , HH.span [ HP.class_ (H.ClassName "timeline-label") ] [ HH.text "Cost" ]
    ]

-- =============================================================================
-- Subscription row with sparkline
-- =============================================================================

renderSubRow :: forall m. Sub -> H.ComponentHTML Action () m
renderSubRow sub =
  HH.div [ HP.class_ (H.ClassName ("sub-row cat-" <> sub.category)) ]
    [ HH.div_
        [ HH.div [ HP.class_ (H.ClassName "sub-row-name") ] [ HH.text sub.name ]
        , HH.div [ HP.class_ (H.ClassName "sub-row-category") ] [ HH.text sub.category ]
        ]
    , HH.div [ HP.class_ (H.ClassName "sub-row-spark") ]
        [ renderSparkline sub ]
    , HH.div_
        [ HH.div [ HP.class_ (H.ClassName "sub-row-amount") ]
            [ HH.text (fmt2 sub.amount <> " " <> sub.currency) ]
        , HH.div [ HP.class_ (H.ClassName "sub-row-freq") ]
            [ HH.text ("/" <> freqLabel sub.frequency) ]
        ]
    ]

-- | SVG sparkline: 12 columns (months), each either filled (charge month)
-- | or empty. Monthly = all filled. Annual = one filled. Quarterly = 4 filled.
renderSparkline :: forall m. Sub -> H.ComponentHTML Action () m
renderSparkline sub =
  let months = chargeMonths sub.frequency
      barWidth = 100.0 / 12.0
      barHeight = 20.0
      color = categoryColor sub.category
  in SE.svg
    [ SA.viewBox 0.0 0.0 100.0 24.0
    , HP.attr (H.AttrName "preserveAspectRatio") "none"
    ]
    (Array.mapWithIndex (\i isCharge ->
      SE.rect
        [ SA.x (toNumber i * barWidth + 0.5)
        , SA.y (if isCharge then 2.0 else barHeight - 2.0)
        , SA.width (barWidth - 1.0)
        , SA.height (if isCharge then barHeight else 2.0)
        , SA.fill (SA.Named (if isCharge then color else "#e8e2d8"))
        , SA.rx 1.0
        , SA.ry 1.0
        ]
    ) months)

-- | Which months have a charge. Returns 12 booleans.
chargeMonths :: String -> Array Boolean
chargeMonths = case _ of
  "monthly"   -> Array.replicate 12 true
  "annual"    -> [ true ] <> Array.replicate 11 false
  "quarterly" -> [ true, false, false, true, false, false, true, false, false, true, false, false ]
  "weekly"    -> Array.replicate 12 true  -- weekly charges every month
  _           -> Array.replicate 12 true

categoryColor :: String -> String
categoryColor = case _ of
  "streaming"  -> "#d4437a"
  "tools"      -> "#4a90d9"
  "insurance"  -> "#c9963a"
  "domain"     -> "#7a7a7a"
  "utility"    -> "#3da35d"
  "membership" -> "#a78bfa"
  _            -> "#8a8078"

-- =============================================================================
-- Summary (RHS)
-- =============================================================================

renderSummary :: forall m. State -> H.ComponentHTML Action () m
renderSummary state =
  let yearly = state.monthlyBurn * 12.0
      daily = state.monthlyBurn / 30.0
  in HH.aside [ HP.class_ (H.ClassName "finance-summary") ]
    [ summaryBlock "Daily average" (fmt2 daily) "/day"
    , summaryBlock "Monthly" (fmt2 state.monthlyBurn) "/mo"
    , summaryBlock "Yearly" (fmt2 yearly) "/yr"
    , summaryBlock "Subscriptions" (show (Array.length state.subs)) "active"
    ]

summaryBlock :: forall m. String -> String -> String -> H.ComponentHTML Action () m
summaryBlock label value unit =
  HH.div [ HP.class_ (H.ClassName "summary-block") ]
    [ HH.div [ HP.class_ (H.ClassName "summary-label") ] [ HH.text label ]
    , HH.div [ HP.class_ (H.ClassName "summary-value") ]
        [ HH.text value
        , HH.span [ HP.class_ (H.ClassName "summary-unit") ] [ HH.text unit ]
        ]
    ]

-- =============================================================================
-- Footer (bottom totals)
-- =============================================================================

renderFooter :: forall m. State -> H.ComponentHTML Action () m
renderFooter state =
  let yearly = state.monthlyBurn * 12.0
  in HH.div [ HP.class_ (H.ClassName "finance-footer") ]
    [ footerTotal "Monthly" (fmt2 state.monthlyBurn)
    , footerTotal "Yearly" (fmt2 yearly)
    , footerTotal "Daily" (fmt2 (state.monthlyBurn / 30.0))
    ]

footerTotal :: forall m. String -> String -> H.ComponentHTML Action () m
footerTotal label value =
  HH.div [ HP.class_ (H.ClassName "footer-total") ]
    [ HH.span [ HP.class_ (H.ClassName "footer-label") ] [ HH.text label ]
    , HH.span [ HP.class_ (H.ClassName "footer-value") ] [ HH.text value ]
    ]

-- =============================================================================
-- Helpers
-- =============================================================================

freqLabel :: String -> String
freqLabel = case _ of
  "monthly"   -> "mo"
  "annual"    -> "yr"
  "quarterly" -> "qtr"
  "weekly"    -> "wk"
  _           -> "?"

fmt2 :: Number -> String
fmt2 = toStringWith (fixed 2)
