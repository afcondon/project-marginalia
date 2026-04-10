-- | Finance visualization — dot-grid cost chart + sparkline timeline.
-- |
-- | Each subscription gets a row with:
-- |   - Name + category (left)
-- |   - A dot grid where each dot ≈ 5 EUR/mo of normalized cost,
-- |     colored by category (center)
-- |   - A thin 12-month sparkline showing charge cadence (center, below dots)
-- |   - Amount + frequency (right)
-- |
-- | RHS summary: daily average, monthly total, yearly total.
-- | Bottom bar: monthly, yearly, daily totals.
module Finance.App where

import Prelude

import Affjax.Web as AX
import Affjax.ResponseFormat as ResponseFormat
import Data.Array as Array
import Data.Either (Either(..))
import Data.Int (floor, toNumber, round)
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
              , HH.div_ (map renderSubRow (sortByMonthlyCost state.subs))
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
    , HH.span [ HP.class_ (H.ClassName "timeline-label") ] [ HH.text "Monthly cost · cadence" ]
    , HH.span [ HP.class_ (H.ClassName "timeline-label") ] [ HH.text "Amount" ]
    ]

-- =============================================================================
-- Subscription row: name | dot grid + sparkline | amount
-- =============================================================================

renderSubRow :: forall m. Sub -> H.ComponentHTML Action () m
renderSubRow sub =
  let monthlyCost = normalizeToMonthly sub
  in HH.div [ HP.class_ (H.ClassName ("sub-row cat-" <> sub.category)) ]
    [ HH.div [ HP.class_ (H.ClassName "sub-row-left") ]
        [ HH.div [ HP.class_ (H.ClassName "sub-row-name") ] [ HH.text sub.name ]
        , HH.div [ HP.class_ (H.ClassName "sub-row-category") ] [ HH.text sub.category ]
        ]
    , HH.div [ HP.class_ (H.ClassName "sub-row-center") ]
        [ renderMonthBlocks sub ]
    , HH.div [ HP.class_ (H.ClassName "sub-row-right") ]
        [ HH.div [ HP.class_ (H.ClassName "sub-row-amount") ]
            [ HH.text (fmt2 sub.amount <> " " <> sub.currency) ]
        , HH.div [ HP.class_ (H.ClassName "sub-row-freq") ]
            [ HH.text ("/" <> freqLabel sub.frequency) ]
        , HH.div [ HP.class_ (H.ClassName "sub-row-monthly") ]
            [ HH.text ("≈ " <> fmt2 monthlyCost <> "/mo") ]
        ]
    ]

-- | 12 months, each rendered as a small block of denomination dots.
-- |
-- | Each amount is decomposed into powers of ten like currency:
-- |   1200 → 1×1000 + 2×100 = 3 dots
-- |   17.99 → 1×10 + 8×1 = 9 dots
-- |   173 → 1×100 + 7×10 + 3×1 = 11 dots
-- |
-- | Each power of ten gets a distinct color so you can read the value
-- | at a glance without counting. Never more than 9 dots per denomination,
-- | typically 3-5 dots total per month block.
-- |
-- | Denomination colors (consistent across all categories):
-- |   1    → light (#c0b8ae)
-- |   10   → medium (#6b8f71)
-- |   100  → strong (#4a6fa5)
-- |   1000 → accent (#8b2020)

-- | Single-denomination dot block. Find the dominant power of ten,
-- | show that many dots in that denomination's color. One color per
-- | block, never more than 9 dots. The color tells you the scale,
-- | the count tells you the magnitude within that scale.
-- |
-- |   1200 → 1 dot red (thousands)
-- |    840 → 8 dots blue (hundreds)
-- |     80 → 8 dots green (tens)
-- |     18 → 2 dots green (tens)
-- |      4 → 4 dots light (ones)
type DotBlock = { count :: Int, color :: String }

denomBlock :: Number -> DotBlock
denomBlock amount =
  let n = round amount
  in if n >= 1000 then { count: min 9 (round (amount / 1000.0)), color: "#8b2020" }
     else if n >= 100 then { count: min 9 (round (amount / 100.0)), color: "#4a6fa5" }
     else if n >= 10 then { count: min 9 (round (amount / 10.0)), color: "#6b8f71" }
     else { count: max 1 n, color: "#c0b8ae" }

renderMonthBlocks :: forall m. Sub -> H.ComponentHTML Action () m
renderMonthBlocks sub =
  let charges = monthlyCharges sub
      dotR = 2.8
      dotSpace = 7.5
      blockCols = 3  -- max dots per row within a block
      blockGap = 5.0

      renderBlock :: Number -> Array (H.ComponentHTML Action () m)
      renderBlock charge =
        if charge < 0.5 then []
        else
          let block = denomBlock charge
          in Array.mapWithIndex (\i _ ->
            let r = i / blockCols
                c = i `mod` blockCols
            in SE.circle
              [ SA.cx (toNumber c * dotSpace + dotR)
              , SA.cy (toNumber r * dotSpace + dotR)
              , SA.r dotR
              , SA.fill (SA.Named block.color)
              ]
          ) (Array.replicate block.count unit)

      -- Max dots in any single month → drives row height
      maxDots = Array.foldl (\acc charge ->
        let n = if charge < 0.5 then 0 else (denomBlock charge).count
        in max acc n) 0 charges
      maxRows = max 1 ((maxDots + blockCols - 1) / blockCols)
      blockHeight = toNumber maxRows * dotSpace + dotR
      blockWidth = toNumber blockCols * dotSpace
      monthWidth = blockWidth + blockGap
      svgWidth = 12.0 * monthWidth
  in SE.svg
    [ SA.viewBox 0.0 0.0 svgWidth (blockHeight + 2.0)
    , HP.attr (H.AttrName "class") "month-blocks-svg"
    ]
    (Array.concat (Array.mapWithIndex (\monthIdx charge ->
      let xOffset = toNumber monthIdx * monthWidth
          dots = renderBlock charge
      in map (\dot -> SE.g [ SA.transform [ SA.Translate xOffset 0.0 ] ] [ dot ]) dots
    ) charges))

-- =============================================================================
-- Summary (RHS)
-- =============================================================================

renderSummary :: forall m. State -> H.ComponentHTML Action () m
renderSummary state =
  let yearly = state.monthlyBurn * 12.0
      daily = state.monthlyBurn / 30.44  -- average days per month
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
      daily = state.monthlyBurn / 30.44
  in HH.div [ HP.class_ (H.ClassName "finance-footer") ]
    [ footerTotal "Monthly" (fmt2 state.monthlyBurn)
    , footerTotal "Yearly" (fmt2 yearly)
    , footerTotal "Daily" (fmt2 daily)
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

-- | Normalize any frequency to monthly cost.
normalizeToMonthly :: Sub -> Number
normalizeToMonthly sub = case sub.frequency of
  "weekly"      -> sub.amount * 4.33
  "fortnightly" -> sub.amount * 26.0 / 12.0
  "monthly"     -> sub.amount
  "quarterly"   -> sub.amount / 3.0
  "annual"      -> sub.amount / 12.0
  _             -> sub.amount

-- | Sort by monthly cost descending so the biggest spends are at the top.
sortByMonthlyCost :: Array Sub -> Array Sub
sortByMonthlyCost = Array.sortBy (\a b -> compare (normalizeToMonthly b) (normalizeToMonthly a))

-- | Actual charge amount per month (12 entries). This is what each
-- | month's dot-block is sized from. Monthly subs have the same amount
-- | every month; annual subs spike in one month; quarterly in four;
-- | fortnightly charges ~2.17 times per month.
monthlyCharges :: Sub -> Array Number
monthlyCharges sub = case sub.frequency of
  "monthly"     -> Array.replicate 12 sub.amount
  "fortnightly" -> Array.replicate 12 (sub.amount * 26.0 / 12.0)
  "weekly"      -> Array.replicate 12 (sub.amount * 4.33)
  "annual"      -> [ sub.amount ] <> Array.replicate 11 0.0
  "quarterly"   -> [ sub.amount, 0.0, 0.0, sub.amount, 0.0, 0.0
                    , sub.amount, 0.0, 0.0, sub.amount, 0.0, 0.0 ]
  _             -> Array.replicate 12 sub.amount

categoryColor :: String -> String
categoryColor = case _ of
  "streaming"  -> "#d4437a"
  "tools"      -> "#4a90d9"
  "insurance"  -> "#c9963a"
  "domain"     -> "#7a7a7a"
  "utility"    -> "#3da35d"
  "membership" -> "#a78bfa"
  _            -> "#8a8078"

freqLabel :: String -> String
freqLabel = case _ of
  "monthly"     -> "mo"
  "fortnightly" -> "2wk"
  "annual"      -> "yr"
  "quarterly"   -> "qtr"
  "weekly"      -> "wk"
  _             -> "?"

fmt2 :: Number -> String
fmt2 = toStringWith (fixed 2)
