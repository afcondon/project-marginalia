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
import Data.Maybe (Maybe(..), fromMaybe)
import Data.String as String
import Effect (Effect)
import Effect.Aff.Class (class MonadAff, liftAff)
import Effect.Class (liftEffect)
import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Events as HE
import Halogen.HTML.Properties as HP

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
  | StartWrite
  | SetNoteText String
  | SaveNote
  | StartUrl
  | SetUrlText String
  | SetUrlComment String
  | SaveUrl
  | CancelCapture

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
  }

-- =============================================================================
-- Render
-- =============================================================================

render :: forall m. State -> H.ComponentHTML Action () m
render state =
  HH.div [ HP.class_ (H.ClassName "capture-app") ]
    [ renderProjectStrip state
    , if state.pickerOpen
        then renderPicker state
        else HH.text ""
    , case state.captureMode of
        Nothing -> renderHome state
        Just mode -> renderCaptureFlow state mode
    ]

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
    [ HH.div [ HP.class_ (H.ClassName "dictate-transcript") ]
        [ HH.text transcript ]
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
    text <- liftAff $ toAffE stopAndTranscribe_
    H.modify_ \s -> s
      { captureMode = Just (DictateReview text)
      , recording = false
      , transcript = text
      }

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

  CancelCapture ->
    H.modify_ \s -> s { captureMode = Nothing, recording = false, noteText = "", urlText = "", urlComment = "", transcript = "" }
