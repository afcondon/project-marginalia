-- | Main component for the Marginalia Capture PWA.
-- |
-- | Single-screen architecture: project strip at the top, 2×2 capture
-- | buttons, recent-captures list, and inline capture flows that replace
-- | the lower half of the screen when active. No page transitions, no
-- | navigation stack. Everything happens in one viewport.
module Capture.App where

import Prelude

import Capture.API as API
import Control.Promise (Promise, toAffE)
import Data.Array as Array
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.Number.Format (toStringWith, fixed)
import Data.String as String
import Effect (Effect)
import Effect.Aff (try)
import Effect.Aff.Class (class MonadAff, liftAff)
import Effect.Class (liftEffect)
import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Events as HE
import Halogen.HTML.Properties as HP
import Web.TouchEvent.Touch as Touch
import Web.TouchEvent.TouchEvent (TouchEvent)
import Web.TouchEvent.TouchEvent as TE
import Web.TouchEvent.TouchList as TL

-- =============================================================================
-- FFI
-- =============================================================================

-- Audio recording (same approach as the desktop frontend)
foreign import startRecording_ :: Effect (Promise Boolean)
foreign import stopAndTranscribe_ :: Effect (Promise String)
foreign import isRecording_ :: Effect Boolean

-- localStorage for sticky project selection
foreign import getStoredProjectId_ :: Effect Int
foreign import setStoredProjectId_ :: Int -> Effect Unit

-- =============================================================================
-- Types
-- =============================================================================

-- | Which capture flow is active (if any). Nothing = home screen.
data CaptureMode
  = Dictating            -- recording in progress
  | DictateReview String -- transcript ready, awaiting save/retry
  | Writing              -- text input open
  | PastingUrl           -- URL + comment input open

derive instance Eq CaptureMode

-- | Top-level screen. Capture and Browse live side-by-side in a swipeable
-- | pane; Dossier is an overlay reached by tapping a card on Browse.
data Screen
  = CaptureHome
  | Browse
  | Dossier Int

derive instance Eq Screen

-- | A recent capture for the confirmation list.
type RecentCapture =
  { projectName :: String
  , content :: String     -- first ~60 chars
  , captureType :: String -- "voice" | "text" | "url" | "photo"
  , timestamp :: String   -- "just now" / "09:42"
  }

type State =
  { projects :: Array API.ProjectSummary
  , currentProject :: Maybe API.ProjectSummary
  , captureMode :: Maybe CaptureMode
  , pickerOpen :: Boolean
  , pickerSearch :: String
  -- Capture state
  , recording :: Boolean
  , transcript :: String
  , noteText :: String
  , urlText :: String
  , urlComment :: String
  -- Recent captures (local, not persisted)
  , recentCaptures :: Array RecentCapture
  , saving :: Boolean
  , error :: Maybe String
  -- Screen + Browse/Dossier state
  , screen :: Screen
  , activityRows :: Array API.ActivitySummary
  , browseLoading :: Boolean
  , dossier :: Maybe API.MobileDossier
  , dossierLoading :: Boolean
  -- Swipe between Capture and Browse tabs
  , swipeStartX :: Maybe Int
  , swipeStartY :: Maybe Int
  , swipeDeltaX :: Int
  , swipeHorizontal :: Boolean
  , swipeAnimating :: Boolean
  }

data Action
  = Initialize
  | LoadProjects
  -- Project picker
  | OpenPicker
  | ClosePicker
  | SetPickerSearch String
  | SelectProject API.ProjectSummary
  -- Capture modes
  | StartDictate
  | StopDictate
  | SaveDictation
  | RetryDictation
  | SetTranscript String
  | StartWrite
  | SetNoteText String
  | SaveNote
  | StartUrl
  | SetUrlText String
  | SetUrlComment String
  | SaveUrl
  | TakePhoto
  | CancelCapture
  -- Screens (Capture tab <-> Browse tab, Dossier overlay)
  | SwitchScreen Screen
  | LoadActivity
  | OpenDossier Int
  | CloseDossier
  -- Swipe gesture between Capture and Browse tabs
  | SwipeStart Int Int
  | SwipeMove Int Int
  | SwipeEnd
  | NoOp

-- =============================================================================
-- Component
-- =============================================================================

component :: forall q i o m. MonadAff m => H.Component q i o m
component = H.mkComponent
  { initialState: \_ -> initialState
  , render
  , eval: H.mkEval $ H.defaultEval
      { handleAction = handleAction
      , initialize = Just Initialize
      }
  }

initialState :: State
initialState =
  { projects: []
  , currentProject: Nothing
  , captureMode: Nothing
  , pickerOpen: false
  , pickerSearch: ""
  , recording: false
  , transcript: ""
  , noteText: ""
  , urlText: ""
  , urlComment: ""
  , recentCaptures: []
  , saving: false
  , error: Nothing
  , screen: CaptureHome
  , activityRows: []
  , browseLoading: false
  , dossier: Nothing
  , dossierLoading: false
  , swipeStartX: Nothing
  , swipeStartY: Nothing
  , swipeDeltaX: 0
  , swipeHorizontal: false
  , swipeAnimating: false
  }

-- =============================================================================
-- Render
-- =============================================================================

render :: forall m. State -> H.ComponentHTML Action () m
render state = case state.screen of
  Dossier _ ->
    HH.div [ HP.class_ (H.ClassName "capture-app capture-app-dossier") ]
      [ renderDossier state ]
  _ ->
    HH.div [ HP.class_ (H.ClassName "capture-app") ]
      [ renderTabBar state
      , renderSwipePane state
      , if state.pickerOpen then renderPicker state else HH.text ""
      ]

-- | Top tab bar — Capture | Browse. Hidden when a dossier is open.
renderTabBar :: forall m. State -> H.ComponentHTML Action () m
renderTabBar state =
  HH.div [ HP.class_ (H.ClassName "tab-bar") ]
    [ renderTab "Capture" CaptureHome (state.screen == CaptureHome)
    , renderTab "Browse" Browse (state.screen == Browse)
    ]

renderTab :: forall m. String -> Screen -> Boolean -> H.ComponentHTML Action () m
renderTab label scr isActive =
  HH.button
    [ HP.class_ (H.ClassName ("tab" <> if isActive then " tab-active" else ""))
    , HE.onClick \_ -> SwitchScreen scr
    ]
    [ HH.text label ]

-- | Swipeable pane containing both the Capture and Browse screens side-by-side.
-- | Pane is 200vw wide; translateX slides between them.
renderSwipePane :: forall m. State -> H.ComponentHTML Action () m
renderSwipePane state =
  let tabIndex = case state.screen of
        Browse -> 1
        _ -> 0
      delta = state.swipeDeltaX
      translate =
        "transform: translateX(calc(-100vw * " <> show tabIndex
          <> " + " <> show delta <> "px));"
      animatingClass = if state.swipeAnimating then " swipe-pane-animating" else ""
  in HH.div
    [ HP.class_ (H.ClassName ("swipe-pane" <> animatingClass))
    , HP.style translate
    , HE.onTouchStart touchStartHandler
    , HE.onTouchMove touchMoveHandler
    , HE.onTouchEnd \_ -> SwipeEnd
    ]
    [ renderCaptureScreen state
    , renderBrowseScreen state
    ]

renderCaptureScreen :: forall m. State -> H.ComponentHTML Action () m
renderCaptureScreen state =
  HH.div [ HP.class_ (H.ClassName "screen screen-capture") ]
    [ renderProjectStrip state
    , case state.captureMode of
        Nothing -> renderHome state
        Just mode -> renderCaptureFlow state mode
    ]

-- | Browse screen: grid of 1×1 mini-cards, sorted by activity score (server-side).
renderBrowseScreen :: forall m. State -> H.ComponentHTML Action () m
renderBrowseScreen state =
  HH.div [ HP.class_ (H.ClassName "screen screen-browse") ]
    [ HH.div [ HP.class_ (H.ClassName "browse-header") ]
        [ HH.span [ HP.class_ (H.ClassName "browse-title") ]
            [ HH.text "Projects" ]
        , HH.span [ HP.class_ (H.ClassName "browse-subtitle") ]
            [ HH.text "by activity" ]
        ]
    , if state.browseLoading && Array.null state.activityRows
        then HH.div [ HP.class_ (H.ClassName "browse-loading") ]
          [ HH.text "loading…" ]
        else HH.div [ HP.class_ (H.ClassName "browse-grid") ]
          (map renderMiniCard state.activityRows)
    ]

renderMiniCard :: forall m. API.ActivitySummary -> H.ComponentHTML Action () m
renderMiniCard row =
  HH.div
    [ HP.class_ (H.ClassName ("mini-card domain-" <> row.domain <> " status-" <> row.status))
    , HE.onClick \_ -> OpenDossier row.id
    ]
    [ HH.div [ HP.class_ (H.ClassName "mini-card-name") ]
        [ HH.text row.name ]
    , HH.div [ HP.class_ (H.ClassName "mini-card-foot") ]
        [ HH.span [ HP.class_ (H.ClassName "mini-card-domain") ]
            [ HH.text row.domain ]
        , HH.span [ HP.class_ (H.ClassName "mini-card-score") ]
            [ HH.text (formatScore row.score) ]
        ]
    ]

formatScore :: Number -> String
formatScore n = toStringWith (fixed 1) n

-- | Read-only dossier view — title, description, notes. Reached by tapping a
-- | mini-card on the Browse screen.
renderDossier :: forall m. State -> H.ComponentHTML Action () m
renderDossier state =
  case state.dossier of
    Nothing ->
      HH.div [ HP.class_ (H.ClassName "dossier-mobile") ]
        [ renderDossierBack
        , HH.div [ HP.class_ (H.ClassName "dossier-loading") ]
            [ HH.text (if state.dossierLoading then "loading…" else "") ]
        ]
    Just d ->
      HH.div [ HP.class_ (H.ClassName ("dossier-mobile domain-" <> d.domain)) ]
        [ renderDossierBack
        , HH.div [ HP.class_ (H.ClassName "dossier-head") ]
            [ HH.h1 [ HP.class_ (H.ClassName "dossier-title") ]
                [ HH.text d.name ]
            , HH.div [ HP.class_ (H.ClassName "dossier-meta") ]
                [ HH.span [ HP.class_ (H.ClassName ("domain-dot domain-" <> d.domain)) ] []
                , HH.span [ HP.class_ (H.ClassName "dossier-domain") ]
                    [ HH.text d.domain ]
                , HH.span [ HP.class_ (H.ClassName "dossier-status") ]
                    [ HH.text d.status ]
                ]
            ]
        , if String.null d.description
            then HH.text ""
            else HH.p [ HP.class_ (H.ClassName "dossier-description") ]
              [ HH.text d.description ]
        , HH.div [ HP.class_ (H.ClassName "dossier-notes") ]
            ( [ HH.div [ HP.class_ (H.ClassName "dossier-notes-label") ]
                  [ HH.text (show (Array.length d.notes) <> " notes") ]
              ] <> map renderDossierNote d.notes
            )
        ]

renderDossierBack :: forall m. H.ComponentHTML Action () m
renderDossierBack =
  HH.button
    [ HP.class_ (H.ClassName "dossier-back")
    , HE.onClick \_ -> CloseDossier
    ]
    [ HH.text "‹ Browse" ]

renderDossierNote :: forall m. API.DossierNote -> H.ComponentHTML Action () m
renderDossierNote note =
  HH.div [ HP.class_ (H.ClassName "dossier-note") ]
    [ HH.div [ HP.class_ (H.ClassName "dossier-note-meta") ]
        [ HH.text (note.author <> " · " <> note.createdAt) ]
    , HH.div [ HP.class_ (H.ClassName "dossier-note-content") ]
        [ HH.text note.content ]
    ]

-- | Touch handlers — extract client X/Y from the first touch; no-op if absent.
touchStartHandler :: TouchEvent -> Action
touchStartHandler ev =
  case TL.item 0 (TE.touches ev) of
    Just t -> SwipeStart (Touch.clientX t) (Touch.clientY t)
    Nothing -> NoOp

touchMoveHandler :: TouchEvent -> Action
touchMoveHandler ev =
  case TL.item 0 (TE.touches ev) of
    Just t -> SwipeMove (Touch.clientX t) (Touch.clientY t)
    Nothing -> NoOp

-- Int abs — local helper to avoid pulling in ring extras.
absI :: Int -> Int
absI n = if n < 0 then -n else n

-- | Top strip: shows current project. Tap to open picker.
renderProjectStrip :: forall m. State -> H.ComponentHTML Action () m
renderProjectStrip state =
  HH.div
    [ HP.class_ (H.ClassName "project-strip")
    , HE.onClick \_ -> OpenPicker
    ]
    [ case state.currentProject of
        Nothing ->
          HH.span [ HP.class_ (H.ClassName "project-strip-empty") ]
            [ HH.text "tap to pick a project" ]
        Just p ->
          HH.div [ HP.class_ (H.ClassName "project-strip-active") ]
            [ HH.span [ HP.class_ (H.ClassName ("domain-dot domain-" <> p.domain)) ] []
            , HH.span [ HP.class_ (H.ClassName "project-strip-name") ]
                [ HH.text p.name ]
            , HH.span [ HP.class_ (H.ClassName "project-strip-domain") ]
                [ HH.text p.domain ]
            ]
    , HH.span [ HP.class_ (H.ClassName "project-strip-chevron") ]
        [ HH.text (if state.pickerOpen then "^" else "v") ]
    ]

-- | Home screen: 2×2 capture buttons + recent captures.
renderHome :: forall m. State -> H.ComponentHTML Action () m
renderHome state =
  HH.div [ HP.class_ (H.ClassName "capture-home") ]
    [ HH.div [ HP.class_ (H.ClassName "capture-buttons") ]
        [ captureButton "dictate" "Dictate" StartDictate (hasProject state)
        , captureButton "write" "Write" StartWrite (hasProject state)
        , captureButton "url" "URL" StartUrl (hasProject state)
        , captureButton "photo" "Photo" TakePhoto (hasProject state)
        ]
    , if Array.null state.recentCaptures
        then HH.text ""
        else renderRecentCaptures state
    , case state.error of
        Nothing -> HH.text ""
        Just err -> HH.div [ HP.class_ (H.ClassName "capture-error") ]
            [ HH.text err ]
    ]

captureButton :: forall m. String -> String -> Action -> Boolean -> H.ComponentHTML Action () m
captureButton cls label action enabled =
  HH.button
    [ HP.class_ (H.ClassName ("capture-btn capture-btn-" <> cls))
    , HP.disabled (not enabled)
    , HE.onClick \_ -> action
    ]
    [ HH.span [ HP.class_ (H.ClassName "capture-btn-label") ]
        [ HH.text label ]
    ]

hasProject :: State -> Boolean
hasProject state = case state.currentProject of
  Just _ -> true
  Nothing -> false

-- | Recent captures list — last 10 captures, most recent first.
renderRecentCaptures :: forall m. State -> H.ComponentHTML Action () m
renderRecentCaptures state =
  HH.div [ HP.class_ (H.ClassName "recent-captures") ]
    [ HH.div [ HP.class_ (H.ClassName "recent-label") ]
        [ HH.text "recent" ]
    , HH.div [ HP.class_ (H.ClassName "recent-list") ]
        (map renderRecentItem state.recentCaptures)
    ]

renderRecentItem :: forall m. RecentCapture -> H.ComponentHTML Action () m
renderRecentItem cap =
  HH.div [ HP.class_ (H.ClassName ("recent-item recent-" <> cap.captureType)) ]
    [ HH.span [ HP.class_ (H.ClassName "recent-time") ]
        [ HH.text cap.timestamp ]
    , HH.span [ HP.class_ (H.ClassName "recent-project") ]
        [ HH.text cap.projectName ]
    , HH.span [ HP.class_ (H.ClassName "recent-content") ]
        [ HH.text (String.take 80 cap.content) ]
    ]

-- =============================================================================
-- Project Picker (bottom sheet)
-- =============================================================================

renderPicker :: forall m. State -> H.ComponentHTML Action () m
renderPicker state =
  HH.div [ HP.class_ (H.ClassName "picker-overlay") ]
    [ HH.div
        [ HP.class_ (H.ClassName "picker-backdrop")
        , HE.onClick \_ -> ClosePicker
        ] []
    , HH.div [ HP.class_ (H.ClassName "picker-sheet") ]
        [ HH.input
            [ HP.class_ (H.ClassName "picker-search")
            , HP.type_ HP.InputText
            , HP.placeholder "Search..."
            , HP.value state.pickerSearch
            , HP.autofocus true
            , HE.onValueInput SetPickerSearch
            ]
        , HH.div [ HP.class_ (H.ClassName "picker-list") ]
            (map (renderPickerItem state) filtered)
        ]
    ]
  where
  filtered =
    let q = String.toLower state.pickerSearch
    in if String.null q
      then state.projects
      else Array.filter (\p -> String.contains (String.Pattern q) (String.toLower p.name)) state.projects

renderPickerItem :: forall m. State -> API.ProjectSummary -> H.ComponentHTML Action () m
renderPickerItem state p =
  let isCurrent = case state.currentProject of
        Just cp -> cp.id == p.id
        Nothing -> false
  in HH.div
    [ HP.class_ (H.ClassName ("picker-item" <> if isCurrent then " picker-item-current" else ""))
    , HE.onClick \_ -> SelectProject p
    ]
    [ HH.span [ HP.class_ (H.ClassName ("domain-dot domain-" <> p.domain)) ] []
    , HH.span [ HP.class_ (H.ClassName "picker-item-name") ]
        [ HH.text p.name ]
    , HH.span [ HP.class_ (H.ClassName "picker-item-status") ]
        [ HH.text p.status ]
    ]

-- =============================================================================
-- Capture Flows
-- =============================================================================

renderCaptureFlow :: forall m. State -> CaptureMode -> H.ComponentHTML Action () m
renderCaptureFlow state = case _ of
  Dictating -> renderDictating state
  DictateReview transcript -> renderDictateReview state transcript
  Writing -> renderWriting state
  PastingUrl -> renderUrlCapture state

renderDictating :: forall m. State -> H.ComponentHTML Action () m
renderDictating _state =
  HH.div [ HP.class_ (H.ClassName "capture-flow capture-dictate") ]
    [ HH.div [ HP.class_ (H.ClassName "dictate-indicator") ]
        [ HH.span [ HP.class_ (H.ClassName "dictate-dot") ] []
        , HH.text "recording"
        ]
    , HH.button
        [ HP.class_ (H.ClassName "dictate-stop")
        , HE.onClick \_ -> StopDictate
        ]
        [ HH.text "tap to stop" ]
    ]

renderDictateReview :: forall m. State -> String -> H.ComponentHTML Action () m
renderDictateReview state transcript =
  HH.div [ HP.class_ (H.ClassName "capture-flow capture-dictate-review") ]
    [ HH.textarea
        [ HP.class_ (H.ClassName "dictate-transcript")
        , HP.value transcript
        , HP.rows 5
        , HE.onValueInput SetTranscript
        ]
    , HH.div [ HP.class_ (H.ClassName "capture-actions") ]
        [ HH.button
            [ HP.class_ (H.ClassName "capture-save")
            , HP.disabled state.saving
            , HE.onClick \_ -> SaveDictation
            ]
            [ HH.text (if state.saving then "saving..." else "Save") ]
        , HH.button
            [ HP.class_ (H.ClassName "capture-retry")
            , HE.onClick \_ -> RetryDictation
            ]
            [ HH.text "Retry" ]
        , HH.button
            [ HP.class_ (H.ClassName "capture-cancel")
            , HE.onClick \_ -> CancelCapture
            ]
            [ HH.text "Cancel" ]
        ]
    ]

renderWriting :: forall m. State -> H.ComponentHTML Action () m
renderWriting state =
  HH.div [ HP.class_ (H.ClassName "capture-flow capture-write") ]
    [ HH.textarea
        [ HP.class_ (H.ClassName "write-input")
        , HP.value state.noteText
        , HP.placeholder "Quick note..."
        , HP.autofocus true
        , HP.rows 4
        , HE.onValueInput SetNoteText
        ]
    , HH.div [ HP.class_ (H.ClassName "capture-actions") ]
        [ HH.button
            [ HP.class_ (H.ClassName "capture-save")
            , HP.disabled (state.saving || String.null (String.trim state.noteText))
            , HE.onClick \_ -> SaveNote
            ]
            [ HH.text (if state.saving then "saving..." else "Save") ]
        , HH.button
            [ HP.class_ (H.ClassName "capture-cancel")
            , HE.onClick \_ -> CancelCapture
            ]
            [ HH.text "Cancel" ]
        ]
    ]

renderUrlCapture :: forall m. State -> H.ComponentHTML Action () m
renderUrlCapture state =
  HH.div [ HP.class_ (H.ClassName "capture-flow capture-url") ]
    [ HH.input
        [ HP.class_ (H.ClassName "url-input")
        , HP.type_ HP.InputUrl
        , HP.value state.urlText
        , HP.placeholder "https://..."
        , HP.autofocus true
        , HE.onValueInput SetUrlText
        ]
    , HH.input
        [ HP.class_ (H.ClassName "url-comment")
        , HP.type_ HP.InputText
        , HP.value state.urlComment
        , HP.placeholder "comment (optional)"
        , HE.onValueInput SetUrlComment
        ]
    , HH.div [ HP.class_ (H.ClassName "capture-actions") ]
        [ HH.button
            [ HP.class_ (H.ClassName "capture-save")
            , HP.disabled (state.saving || String.null (String.trim state.urlText))
            , HE.onClick \_ -> SaveUrl
            ]
            [ HH.text (if state.saving then "saving..." else "Save") ]
        , HH.button
            [ HP.class_ (H.ClassName "capture-cancel")
            , HE.onClick \_ -> CancelCapture
            ]
            [ HH.text "Cancel" ]
        ]
    ]

-- =============================================================================
-- Action Handler
-- =============================================================================

handleAction :: forall o m. MonadAff m =>
  Action -> H.HalogenM State Action () o m Unit
handleAction = case _ of
  Initialize -> do
    handleAction LoadProjects
    -- Restore last-used project from localStorage
    storedId <- liftEffect getStoredProjectId_
    when (storedId > 0) do
      state <- H.get
      case Array.find (\p -> p.id == storedId) state.projects of
        Just p -> H.modify_ \s -> s { currentProject = Just p }
        Nothing -> pure unit

  LoadProjects -> do
    projects <- liftAff API.fetchProjects
    H.modify_ \s -> s { projects = projects }

  -- Picker
  OpenPicker ->
    H.modify_ \s -> s { pickerOpen = true, pickerSearch = "" }

  ClosePicker ->
    H.modify_ \s -> s { pickerOpen = false }

  SetPickerSearch q ->
    H.modify_ \s -> s { pickerSearch = q }

  SelectProject p -> do
    liftEffect $ setStoredProjectId_ p.id
    H.modify_ \s -> s { currentProject = Just p, pickerOpen = false }

  -- Dictate
  StartDictate -> do
    started <- liftAff $ toAffE startRecording_
    when started do
      H.modify_ \s -> s { captureMode = Just Dictating, recording = true, error = Nothing }

  StopDictate -> do
    result <- liftAff $ try $ toAffE stopAndTranscribe_
    case result of
      Right text ->
        H.modify_ \s -> s
          { captureMode = Just (DictateReview text)
          , recording = false
          , transcript = text
          }
      Left _ ->
        H.modify_ \s -> s
          { captureMode = Nothing
          , recording = false
          , error = Just "Transcription failed — is whisper running?"
          }

  SetTranscript v ->
    H.modify_ \s -> s { transcript = v, captureMode = Just (DictateReview v) }

  SaveDictation -> do
    state <- H.get
    case state.currentProject of
      Nothing -> pure unit
      Just p -> do
        H.modify_ \s -> s { saving = true }
        ok <- liftAff $ API.addNote p.id state.transcript
        if ok
          then do
            let cap = { projectName: p.name, content: state.transcript, captureType: "voice", timestamp: "just now" }
            H.modify_ \s -> s
              { captureMode = Nothing, saving = false, transcript = ""
              , recentCaptures = Array.cons cap (Array.take 9 s.recentCaptures)
              }
          else H.modify_ \s -> s { saving = false, error = Just "Failed to save note" }

  RetryDictation -> do
    started <- liftAff $ toAffE startRecording_
    when started do
      H.modify_ \s -> s { captureMode = Just Dictating, recording = true, transcript = "" }

  -- Write
  StartWrite ->
    H.modify_ \s -> s { captureMode = Just Writing, noteText = "", error = Nothing }

  SetNoteText v ->
    H.modify_ \s -> s { noteText = v }

  SaveNote -> do
    state <- H.get
    case state.currentProject of
      Nothing -> pure unit
      Just p -> do
        let text = String.trim state.noteText
        when (not (String.null text)) do
          H.modify_ \s -> s { saving = true }
          ok <- liftAff $ API.addNote p.id text
          if ok
            then do
              let cap = { projectName: p.name, content: text, captureType: "text", timestamp: "just now" }
              H.modify_ \s -> s
                { captureMode = Nothing, saving = false, noteText = ""
                , recentCaptures = Array.cons cap (Array.take 9 s.recentCaptures)
                }
            else H.modify_ \s -> s { saving = false, error = Just "Failed to save note" }

  -- URL
  StartUrl ->
    H.modify_ \s -> s { captureMode = Just PastingUrl, urlText = "", urlComment = "", error = Nothing }

  SetUrlText v ->
    H.modify_ \s -> s { urlText = v }

  SetUrlComment v ->
    H.modify_ \s -> s { urlComment = v }

  SaveUrl -> do
    state <- H.get
    case state.currentProject of
      Nothing -> pure unit
      Just p -> do
        let url = String.trim state.urlText
        when (not (String.null url)) do
          let body = url <> (if String.null (String.trim state.urlComment) then "" else "\n\n" <> String.trim state.urlComment)
          H.modify_ \s -> s { saving = true }
          ok <- liftAff $ API.addNote p.id body
          if ok
            then do
              let cap = { projectName: p.name, content: url, captureType: "url", timestamp: "just now" }
              H.modify_ \s -> s
                { captureMode = Nothing, saving = false, urlText = "", urlComment = ""
                , recentCaptures = Array.cons cap (Array.take 9 s.recentCaptures)
                }
            else H.modify_ \s -> s { saving = false, error = Just "Failed to save URL" }

  TakePhoto -> do
    state <- H.get
    case state.currentProject of
      Nothing -> pure unit
      Just p -> do
        H.modify_ \s -> s { error = Nothing }
        filename <- liftAff $ toAffE $ API.pickAndUploadPhoto p.id
        if String.null filename
          then pure unit -- user cancelled
          else do
            let cap = { projectName: p.name, content: filename, captureType: "photo", timestamp: "just now" }
            H.modify_ \s -> s
              { recentCaptures = Array.cons cap (Array.take 9 s.recentCaptures) }

  CancelCapture ->
    H.modify_ \s -> s { captureMode = Nothing, recording = false, noteText = "", urlText = "", urlComment = "", transcript = "" }

  -- =============================================================================
  -- Screen switching
  -- =============================================================================

  SwitchScreen scr -> case scr of
    CaptureHome ->
      H.modify_ \s -> s
        { screen = CaptureHome
        , swipeDeltaX = 0
        , swipeStartX = Nothing
        , swipeStartY = Nothing
        , swipeHorizontal = false
        , swipeAnimating = true
        }
    Browse -> do
      H.modify_ \s -> s
        { screen = Browse
        , swipeDeltaX = 0
        , swipeStartX = Nothing
        , swipeStartY = Nothing
        , swipeHorizontal = false
        , swipeAnimating = true
        }
      handleAction LoadActivity
    Dossier pid -> handleAction (OpenDossier pid)

  LoadActivity -> do
    H.modify_ \s -> s { browseLoading = true }
    rows <- liftAff API.fetchActivity
    H.modify_ \s -> s { activityRows = rows, browseLoading = false }

  OpenDossier pid -> do
    H.modify_ \s -> s
      { screen = Dossier pid
      , dossier = Nothing
      , dossierLoading = true
      }
    d <- liftAff $ API.fetchDossier pid
    H.modify_ \s -> s { dossier = d, dossierLoading = false }

  CloseDossier ->
    H.modify_ \s -> s
      { screen = Browse
      , dossier = Nothing
      , dossierLoading = false
      }

  -- =============================================================================
  -- Swipe between Capture <-> Browse
  -- =============================================================================

  SwipeStart x y -> do
    state <- H.get
    let inCaptureFlow = case state.captureMode of
          Just _ -> true
          Nothing -> false
    let onDossier = case state.screen of
          Dossier _ -> true
          _ -> false
    when (not inCaptureFlow && not state.pickerOpen && not onDossier) $
      H.modify_ \s -> s
        { swipeStartX = Just x
        , swipeStartY = Just y
        , swipeDeltaX = 0
        , swipeHorizontal = false
        , swipeAnimating = false
        }

  SwipeMove x y -> do
    state <- H.get
    case state.swipeStartX, state.swipeStartY of
      Just sx, Just sy ->
        -- Clamp swipe to valid direction: nothing to the right of Capture,
        -- nothing to the left of Browse. Prevents over-swipe into empty space.
        let rawDx = x - sx
            dy = y - sy
            dx = case state.screen of
              CaptureHome -> min 0 rawDx
              Browse -> max 0 rawDx
              Dossier _ -> 0
        in if state.swipeHorizontal
             then H.modify_ \s -> s { swipeDeltaX = dx }
             else when (absI rawDx > 10 && absI rawDx > (3 * absI dy) / 2) $
               H.modify_ \s -> s { swipeHorizontal = true, swipeDeltaX = dx }
      _, _ -> pure unit

  SwipeEnd -> do
    state <- H.get
    if state.swipeHorizontal
      then do
        let threshold = 80
        let dx = state.swipeDeltaX
        case state.screen of
          CaptureHome ->
            if dx < -threshold
              then handleAction (SwitchScreen Browse)
              else H.modify_ \s -> s
                { swipeDeltaX = 0
                , swipeAnimating = true
                , swipeStartX = Nothing
                , swipeStartY = Nothing
                , swipeHorizontal = false
                }
          Browse ->
            if dx > threshold
              then handleAction (SwitchScreen CaptureHome)
              else H.modify_ \s -> s
                { swipeDeltaX = 0
                , swipeAnimating = true
                , swipeStartX = Nothing
                , swipeStartY = Nothing
                , swipeHorizontal = false
                }
          Dossier _ -> pure unit
      else
        H.modify_ \s -> s
          { swipeDeltaX = 0
          , swipeStartX = Nothing
          , swipeStartY = Nothing
          , swipeHorizontal = false
          , swipeAnimating = false
          }

  NoOp -> pure unit
