-- | Main application shell component for Project Tracker.
-- |
-- | Single-component architecture: filter bar, stats summary, project list,
-- | detail panel, and create/edit form all managed in one component's state.
module Component.App where

import Prelude

import API as API
import API (SubscriptionRecord) as API
import Control.Promise (Promise, toAffE)
import Data.Array as Array
import Data.Int (floor, fromString) as Int
import Data.Maybe (Maybe(..), fromMaybe, isJust)
import Data.String as String
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Aff.Class (class MonadAff, liftAff)
import Effect.Class (liftEffect)
import Foreign.Object as FO
import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Events as HE
import Halogen.HTML.Properties as HP
import Halogen.Subscription as HS
import Types (Attachment, BlogStatus(..), Project, ProjectDetail, Server, Stats, ProjectInput, Status(..), allBlogStatuses, allStatuses, blogStatusLabel, blogStatusToString, statusLabel, statusToString, nextStatuses)
import Web.Event.Event (Event)
import Web.UIEvent.MouseEvent (MouseEvent, toEvent)

-- =============================================================================
-- FFI
-- =============================================================================

foreign import stopPropagation_ :: Event -> Effect Unit
foreign import getHash_ :: Effect String
foreign import setHash_ :: String -> Effect Unit
foreign import onHashChange_ :: (String -> Effect Unit) -> Effect (Effect Unit)
foreign import focusSearch_ :: Effect Unit
foreign import blurActive_ :: Effect Unit
foreign import getGridColumns_ :: Effect Int
foreign import focusNoteInput_ :: Effect Unit
foreign import altKey_ :: Event -> Effect Boolean

-- Audio recording
foreign import startRecording_ :: Effect (Promise Boolean)
foreign import stopAndTranscribe_ :: Effect (Promise String)
foreign import isRecording_ :: Effect Boolean

type KeyEvent =
  { key :: String
  , ctrl :: Boolean
  , meta :: Boolean
  , shift :: Boolean
  , isInput :: Boolean
  , preventDefault :: Effect Unit
  }

foreign import onKeyDown_ :: (KeyEvent -> Effect Unit) -> Effect (Effect Unit)

-- =============================================================================
-- Types
-- =============================================================================

-- | Which view/panel is currently active
data View
  = ListView
  | DetailView Int
  | CreateView

derive instance Eq View

-- | How to render a project detail. Different domains may eventually get
-- | different layouts (Dossier for WSJ-style fact-and-figure work, Magazine
-- | for Pinterest-ish ideaboards, Workshop for photo-heavy projects, etc.).
-- | The persisted preference lives on the project row; this ADT is just the
-- | rendering-time discriminator.
data DetailViewKind = DossierView | MagazineView

derive instance Eq DetailViewKind

-- | Translate the persisted "preferred_view" string to a renderer kind.
-- | Unknown / missing values default to DossierView.
parseViewKind :: Maybe String -> DetailViewKind
parseViewKind = case _ of
  Just "magazine" -> MagazineView
  _               -> DossierView

viewKindToString :: DetailViewKind -> String
viewKindToString = case _ of
  DossierView  -> "dossier"
  MagazineView -> "magazine"

-- | Visual tier for a project card in the Register (index) view.
-- | Each tier maps to a different footprint in the 4-column CSS grid:
-- |   Lead     — 4 cols × 2 rows (a whole-page banner story)
-- |   Feature  — 2 cols × 3 rows (a tall magazine feature)
-- |   Portrait — 1 col  × 2 rows (a half-column sidebar piece)
-- |   Regular  — 2 cols × 1 row  (a standard register entry)
-- |   Small    — 1 col  × 1 row  (a stub / fill entry)
-- | CSS `grid-auto-flow: dense` backfills small holes, so the mix of
-- | footprints produces the newspaper-ish layout without us having to
-- | solve any packing problem ourselves.
data CardTier
  = Lead
  | Feature
  | Portrait
  | Regular
  | Small

derive instance Eq CardTier

tierClass :: CardTier -> String
tierClass = case _ of
  Lead     -> "tier-lead"
  Feature  -> "tier-feature"
  Portrait -> "tier-portrait"
  Regular  -> "tier-regular"
  Small    -> "tier-small"

-- | Decide what size a project card should be in the Register.
-- |
-- | Design note: we deliberately keep almost every project at Small or
-- | Regular. The bigger tiers (Lead, Feature, Portrait) are reserved for:
-- |   * the first card in the list (always Lead — use ordering to put a
-- |     strong candidate there)
-- |   * projects with a cover screenshot attachment (promoted to Feature
-- |     because the image needs space to read)
-- |   * manual overrides via "hero" tag (→ Lead) or "featured" (→ Feature)
-- |
-- | Between Regular and Small we use a light content signal (description
-- | length or tag count) so project stubs that haven't been filled out
-- | yet stay small and out of the way.
pickTier :: Int -> Project -> CardTier
pickTier idx project =
  let
    hasTag t = Array.elem t project.tags
    hasCover = isJust project.coverUrl

    descLen = case project.description of
      Nothing -> 0
      Just d  -> String.length d

    baseline =
      if descLen >= 150 || Array.length project.tags >= 2 then Regular
      else Small
  in
    if idx == 0 then Lead
    else if hasTag "hero" then Lead
    else if hasCover then Feature
    else if hasTag "featured" then Feature
    else baseline

-- | Fields in the Dossier view that are editable via plain click-to-edit.
-- | Title uses the existing rename flow (has directory-rename side effects).
-- | Status uses QuickStatusChange (has transition validation).
-- | Everything else goes through the generic DossierStartEdit/CommitEdit path.
data EditableField
  = FDescription
  | FSubdomain
  | FRepo
  | FSourceUrl
  | FSourcePath
  | FBlogContent

derive instance Eq EditableField

fieldLabel :: EditableField -> String
fieldLabel = case _ of
  FDescription -> "description"
  FSubdomain -> "subdomain"
  FRepo -> "repo"
  FSourceUrl -> "source url"
  FSourcePath -> "source path"
  FBlogContent -> "blog post"

-- | Which newspaper section is active. Nothing = the default project Register.
-- | Named sections pull from different data sources — Finance from the
-- | subscriptions table, etc. The Register layout and card renderer change
-- | based on the active section.
type Section = String  -- "finance" for now; more later

type State =
  { projects :: Array Project
  , selectedProject :: Maybe ProjectDetail
  , stats :: Maybe Stats
  , view :: View
  , section :: Maybe Section  -- Nothing = projects, Just "finance" = subscriptions
  , subscriptions :: Array API.SubscriptionRecord
  , subscriptionMonthlyBurn :: Number
  , filterDomain :: Maybe String
  , filterStatus :: Maybe String
  , filterTag :: Maybe String
  , filterAncestor :: Maybe { id :: Int, name :: String }
  , filterDepth :: Maybe Int  -- 0 = leaves, 1 = parents, 2 = grandparents
  , allProjects :: Array Project  -- unfiltered cache for ancestor/depth lookups
  , servers :: Array Server        -- full port registry for lookups on cards and in detail
  , searchText :: String
  , loading :: Boolean
  , error :: Maybe String
  -- Form fields (shared for create and edit)
  , formName :: String
  , formDomain :: String
  , formSubdomain :: String
  , formStatus :: String
  , formDescription :: String
  , formRepo :: String
  , formSourceUrl :: String
  , formSourcePath :: String
  -- Keyboard navigation
  , focusIndex :: Int  -- which card is focused (-1 = none)
  -- Quick note
  , notePanel :: Boolean       -- is note panel open?
  , noteProjectId :: Maybe Int -- which project are we adding a note to?
  , noteText :: String         -- note content being composed
  , recording :: Boolean       -- currently recording audio?
  -- Add-child inline form
  , addChildOpen :: Maybe Int  -- project id we're adding a child to
  , addChildName :: String
  -- Inline rename
  , renameOpen :: Maybe Int  -- project id being renamed
  , renameValue :: String
  , renameDirectory :: Boolean  -- also rename the source directory?
  -- Dossier inline editing. Only one field at a time.
  , detailViewKind :: DetailViewKind
  , dossierEditField :: Maybe EditableField
  , dossierEditValue :: String
  , dossierDomainOpen :: Boolean    -- domain dropdown visible?
  , dossierNoteOpen :: Boolean      -- inline note composer visible?
  , dossierNoteDraft :: String
  , dossierTagOpen :: Boolean       -- new-tag input visible?
  , dossierTagDraft :: String
  }

data Action
  = Initialize
  | LoadProjects
  | LoadAllProjects
  | LoadPorts
  | LoadStats
  | SetSection (Maybe Section)  -- switch newspaper section
  | LoadSubscriptions
  | SetFilterDomain String
  | SetFilterStatus String
  | SetFilterTag String
  | TagClick String MouseEvent
  | SetFilterAncestor (Maybe { id :: Int, name :: String })
  | SetFilterDepth (Maybe Int)
  | SetSearchText String
  | ClearFilters
  | ApplyFilters
  | SelectProject Int
  | CloseDetail
  | ShowCreateForm
  | CancelForm
  | SubmitCreate
  | SetFormName String
  | QuickStatusChange Int Status MouseEvent
  | NextProject
  | PrevProject
  | NavigateToParent
  | HashChange String
  | AutoSave Int
  | KeyDown KeyEvent
  | OpenNotePanel Int
  | CloseNotePanel
  | SetNoteText String
  | SubmitNote
  | ToggleRecording
  | OpenAddChild Int
  | CloseAddChild
  | SetAddChildName String
  | SubmitAddChild Int
  | StartRename Int String
  | CancelRename
  | SetRenameValue String
  | ToggleRenameDirectory
  | SubmitRename Int
  | ClearStatus
  | DeleteServerAction Int  -- server id
  -- Dossier view inline editing
  | DossierStartEdit EditableField String
  | DossierSetEditValue String
  | DossierCommitEdit
  | DossierCancelEdit
  | DossierSetView DetailViewKind   -- switch between Dossier and Magazine
  | DossierOpenDomain
  | DossierPickDomain String
  | DossierOpenNote
  | DossierSetNote String
  | DossierSubmitNote
  | DossierCancelNote
  | DossierOpenTag
  | DossierSetTag String
  | DossierSubmitTag
  | DossierCancelTag
  -- Blog-post classification
  | SetBlogStatus (Maybe BlogStatus) MouseEvent

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
  , selectedProject: Nothing
  , stats: Nothing
  , view: ListView
  , section: Nothing
  , subscriptions: []
  , subscriptionMonthlyBurn: 0.0
  , filterDomain: Nothing
  , filterStatus: Nothing
  , filterTag: Nothing
  , filterAncestor: Nothing
  , filterDepth: Nothing
  , allProjects: []
  , servers: []
  , searchText: ""
  , loading: true
  , error: Nothing
  , formName: ""
  , formDomain: "programming"
  , formSubdomain: ""
  , formStatus: "idea"
  , formDescription: ""
  , formRepo: ""
  , formSourceUrl: ""
  , formSourcePath: ""
  , focusIndex: -1
  , notePanel: false
  , noteProjectId: Nothing
  , noteText: ""
  , recording: false
  , addChildOpen: Nothing
  , addChildName: ""
  , renameOpen: Nothing
  , renameValue: ""
  , renameDirectory: false
  , detailViewKind: DossierView
  , dossierEditField: Nothing
  , dossierEditValue: ""
  , dossierDomainOpen: false
  , dossierNoteOpen: false
  , dossierNoteDraft: ""
  , dossierTagOpen: false
  , dossierTagDraft: ""
  }

-- =============================================================================
-- Render
-- =============================================================================

render :: forall m. State -> H.ComponentHTML Action () m
render state =
  HH.div [ HP.class_ (H.ClassName "app-shell") ]
    [ -- Header only shown when browsing the list (it IS the index masthead).
      -- Dossier-style views (DetailView, CreateView) have their own top strip.
      case state.view of
        DetailView _ -> HH.text ""
        CreateView   -> HH.text ""
        _ -> renderHeader state
    , HH.main [ HP.class_ (H.ClassName "main-content") ]
        [ case state.view of
            CreateView -> renderCreateDossier state
            DetailView _ -> case state.selectedProject of
              Nothing -> renderLoading
              Just detail -> case parseViewKind detail.preferredView of
                DossierView  -> renderDossier state detail
                MagazineView -> renderMagazine state detail
            ListView -> case state.section of
              Just "finance" -> renderFinanceSection state
              _              -> renderProjectList state
        ]
    -- Keyboard shortcut hint (shown when no card is focused on the list)
    , if state.view == ListView && state.focusIndex < 0
        then HH.div [ HP.class_ (H.ClassName "keyboard-hint") ]
          [ HH.text "hjkl navigate  /search  enter open  1-7 status  e edit  n note  i inbox  esc close" ]
        else HH.text ""
    -- Toast/status message (rename warnings, errors, etc.)
    , case state.error of
        Nothing -> HH.text ""
        Just msg -> HH.div
          [ HP.class_ (H.ClassName "status-toast")
          , HE.onClick \_ -> ClearStatus
          ]
          [ HH.text msg ]
    -- Quick note panel (floating at bottom)
    , if state.notePanel
        then renderNotePanel state
        else HH.text ""
    ]

renderNotePanel :: forall m. State -> H.ComponentHTML Action () m
renderNotePanel state =
  let projectName = case state.noteProjectId of
        Nothing -> ""
        Just pid ->
          if pid == inboxProjectId then "Claude Inbox"
          else case Array.find (\p -> p.id == pid) state.projects of
            Nothing -> "Project #" <> show pid
            Just p -> p.name
  in HH.div [ HP.class_ (H.ClassName "note-panel") ]
    [ HH.div [ HP.class_ (H.ClassName "note-panel-header") ]
        [ HH.span [ HP.class_ (H.ClassName "note-panel-title") ]
            [ HH.text ("Note on: " <> projectName) ]
        , HH.button
            [ HP.class_ (H.ClassName ("btn note-record-btn" <> if state.recording then " recording" else ""))
            , HE.onClick \_ -> ToggleRecording
            ]
            [ HH.text (if state.recording then "Stop" else "Record") ]
        , HH.button
            [ HP.class_ (H.ClassName "btn btn-back")
            , HE.onClick \_ -> CloseNotePanel
            ]
            [ HH.text "X" ]
        ]
    , HH.textarea
        [ HP.class_ (H.ClassName "note-input-textarea")
        , HP.value state.noteText
        , HP.placeholder "Type or dictate a note..."
        , HP.rows 3
        , HE.onValueInput SetNoteText
        ]
    , HH.div [ HP.class_ (H.ClassName "note-panel-actions") ]
        [ HH.button
            [ HP.class_ (H.ClassName "btn btn-primary")
            , HP.disabled (String.null state.noteText)
            , HE.onClick \_ -> SubmitNote
            ]
            [ HH.text "Save note" ]
        ]
    ]

renderSlidePanel :: forall m. Boolean -> H.ComponentHTML Action () m -> H.ComponentHTML Action () m
renderSlidePanel isOpen content =
  HH.div_
    [ HH.div
        [ HP.class_ (H.ClassName ("slide-overlay" <> if isOpen then " open" else ""))
        , HE.onClick \_ -> CloseDetail
        ]
        []
    , HH.div [ HP.class_ (H.ClassName ("slide-panel" <> if isOpen then " open" else "")) ]
        [ content ]
    ]

renderHeader :: forall m. State -> H.ComponentHTML Action () m
renderHeader state =
  HH.header [ HP.class_ (H.ClassName "app-header") ]
    [ HH.div [ HP.class_ (H.ClassName "header-inner") ]
        [ HH.div [ HP.class_ (H.ClassName "header-top") ]
            [ HH.h1
                [ HP.class_ (H.ClassName "app-title")
                , HE.onClick \_ -> ClearFilters
                ]
                [ HH.text (show (Array.length state.projects) <> " projects") ]
            , case state.filterTag of
                Nothing -> HH.text ""
                Just tag -> HH.span
                  [ HP.class_ (H.ClassName "active-tag-filter")
                  , HE.onClick \_ -> SetFilterTag ""
                  , HP.title "Click to clear tag filter"
                  ]
                  [ HH.text ("#" <> tag) ]
            , renderStatusFilterLights state
            , HH.input
                [ HP.class_ (H.ClassName "header-search")
                , HP.type_ HP.InputText
                , HP.placeholder "Search..."
                , HP.value state.searchText
                , HE.onValueInput SetSearchText
                ]
            , HH.div [ HP.class_ (H.ClassName "header-actions") ]
                [ if hasActiveFilters state
                    then HH.button
                      [ HP.class_ (H.ClassName "btn btn-back")
                      , HE.onClick \_ -> ClearFilters
                      ]
                      [ HH.text "Clear" ]
                    else HH.text ""
                , HH.button
                    [ HP.class_ (H.ClassName "btn btn-primary")
                    , HE.onClick \_ -> ShowCreateForm
                    ]
                    [ HH.text "New Project" ]
                ]
            ]
        , renderDomainFilterBar state
        ]
    ]

-- | Status filter as traffic light dots in the header (same visual as card dots)
renderStatusFilterLights :: forall m. State -> H.ComponentHTML Action () m
renderStatusFilterLights state =
  HH.div [ HP.class_ (H.ClassName "header-status-lights") ]
    (map (renderStatusFilterLight state) allStatuses)

renderStatusFilterLight :: forall m. State -> Status -> H.ComponentHTML Action () m
renderStatusFilterLight state status =
  let statusStr = statusToString status
      isActive = state.filterStatus == Just statusStr
      clickVal = if isActive then "" else statusStr
      lightClass = "status-light status-light-" <> statusStr
        <> (if isActive then " current" else "")
  in HH.button
    [ HP.class_ (H.ClassName lightClass)
    , HP.title (statusLabel status)
    , HE.onClick \_ -> SetFilterStatus clickVal
    ]
    []

-- | Domain pills row (second line of header) — also includes the depth (P-rank) pills.
renderDomainFilterBar :: forall m. State -> H.ComponentHTML Action () m
renderDomainFilterBar state =
  HH.div [ HP.class_ (H.ClassName "header-domains") ]
    (renderSectionPills state <> renderDomainPills state <> renderDepthPills state)

-- | Section pills — newspaper sections beyond the project domains.
-- | Currently just FINANCE; more to come (Weather, Culture, Sports...).
renderSectionPills :: forall m. State -> Array (H.ComponentHTML Action () m)
renderSectionPills state =
  [ renderSectionPill state "finance" "FINANCE" (Array.length state.subscriptions) ]

renderSectionPill :: forall m. State -> String -> String -> Int -> H.ComponentHTML Action () m
renderSectionPill state sectionId label count =
  let isActive = state.section == Just sectionId
      activeClass = if isActive then " filter-pill-active section-pill-active" else ""
  in HH.button
    [ HP.class_ (H.ClassName ("filter-pill section-pill section-" <> sectionId <> activeClass))
    , HE.onClick \_ -> SetSection (if isActive then Nothing else Just sectionId)
    ]
    [ HH.text label
    , if count > 0
        then HH.span [ HP.class_ (H.ClassName "pill-count") ]
          [ HH.text (" (" <> show count <> ")") ]
        else HH.text ""
    ]

-- | Always-visible P0/P1/P2 radio buttons.
-- | P0 = leaves (no children), P1 = parents (have children but no grandchildren),
-- | P2 = grandparents (have grandchildren).
renderDepthPills :: forall m. State -> Array (H.ComponentHTML Action () m)
renderDepthPills state =
  [ depthPill 0 "P0", depthPill 1 "P1", depthPill 2 "P2" ]
  where
  depthPill :: Int -> String -> H.ComponentHTML Action () m
  depthPill d label =
    let isActive = state.filterDepth == Just d
        activeClass = if isActive then " filter-pill-active" else ""
        count = Array.length (Array.filter (\p -> projectHeight state.allProjects p.id == d) state.allProjects)
    in HH.button
      [ HP.class_ (H.ClassName ("filter-pill depth-pill" <> activeClass))
      , HP.title (depthDescription d)
      , HE.onClick \_ -> SetFilterDepth (if isActive then Nothing else Just d)
      ]
      [ HH.text label
      , HH.span [ HP.class_ (H.ClassName "pill-count") ]
          [ HH.text (" (" <> show count <> ")") ]
      ]

  depthDescription :: Int -> String
  depthDescription = case _ of
    0 -> "Leaves: projects with no children"
    1 -> "Parents: have children but no grandchildren"
    2 -> "Grandparents: top-level rollups"
    _ -> ""

-- | Compute the "height" of a project: 0 if leaf, 1 if has only leaf children,
-- | 2 if has grandchildren, etc.
projectHeight :: Array Project -> Int -> Int
projectHeight projects pid =
  let children = Array.filter (\p -> p.parentId == Just pid) projects
  in if Array.null children
    then 0
    else 1 + Array.foldr max 0 (map (\c -> projectHeight projects c.id) children)

hasActiveFilters :: State -> Boolean
hasActiveFilters state =
  isJust state.filterDomain || isJust state.filterStatus || isJust state.filterTag
    || isJust state.filterAncestor || isJust state.filterDepth
    || not (String.null state.searchText)

-- =============================================================================
-- Filter Helpers
-- =============================================================================

-- | Domain pill count: stats.byDomain[D].total (always global)
domainPillCount :: Stats -> String -> Int
domainPillCount stats domain =
  case Array.find (\ds -> ds.domain == domain) stats.byDomain of
    Nothing -> 0
    Just ds -> ds.total

-- | Status pill count: if domain filter active, look in that domain; else sum across all
statusPillCount :: Stats -> Maybe String -> Status -> Int
statusPillCount stats mDomain status =
  let key = statusToString status
  in case mDomain of
    Just domain ->
      case Array.find (\ds -> ds.domain == domain) stats.byDomain of
        Nothing -> 0
        Just ds -> fromMaybe 0 (FO.lookup key ds.statuses)
    Nothing ->
      Array.foldl (\acc ds -> acc + fromMaybe 0 (FO.lookup key ds.statuses)) 0 stats.byDomain

renderDomainPills :: forall m. State -> Array (H.ComponentHTML Action () m)
renderDomainPills state = case state.stats of
  Nothing -> []
  Just stats -> map (renderDomainPill state stats) stats.domains

renderDomainPill :: forall m. State -> Stats -> String -> H.ComponentHTML Action () m
renderDomainPill state stats domain =
  let isActive = state.filterDomain == Just domain
      count = domainPillCount stats domain
      activeClass = if isActive then " filter-pill-active" else ""
      clickVal = if isActive then "" else domain
  in HH.button
    [ HP.class_ (H.ClassName ("filter-pill domain-pill domain-" <> domain <> activeClass))
    , HE.onClick \_ -> SetFilterDomain clickVal
    ]
    [ HH.text domain
    , HH.span [ HP.class_ (H.ClassName "pill-count") ]
        [ HH.text (" (" <> show count <> ")") ]
    ]


-- =============================================================================
-- Project List
-- =============================================================================

renderProjectList :: forall m. State -> H.ComponentHTML Action () m
renderProjectList state =
  HH.div [ HP.class_ (H.ClassName "project-list") ]
    [ if state.loading
        then renderLoading
        else if Array.null state.projects
          then HH.div [ HP.class_ (H.ClassName "empty-state") ]
                [ HH.text "No projects found." ]
          else HH.div [ HP.class_ (H.ClassName "project-cards") ]
                (Array.mapWithIndex (\i p -> renderProjectCard state i p) state.projects)
    ]

-- =============================================================================
-- Finance Section — subscription cards
-- =============================================================================

renderFinanceSection :: forall m. State -> H.ComponentHTML Action () m
renderFinanceSection state =
  HH.div [ HP.class_ (H.ClassName "finance-section") ]
    [ HH.div [ HP.class_ (H.ClassName "finance-header") ]
        [ HH.span [ HP.class_ (H.ClassName "finance-burn") ]
            [ HH.text ("~" <> show (Int.floor state.subscriptionMonthlyBurn) <> "/mo") ]
        , HH.span [ HP.class_ (H.ClassName "finance-count") ]
            [ HH.text (show (Array.length state.subscriptions) <> " active") ]
        ]
    , if Array.null state.subscriptions
        then HH.div [ HP.class_ (H.ClassName "empty-state") ]
          [ HH.text "No subscriptions tracked yet." ]
        else HH.div [ HP.class_ (H.ClassName "project-cards") ]
          (Array.mapWithIndex (\i s -> renderSubscriptionCard i s) state.subscriptions)
    ]

renderSubscriptionCard :: forall m. Int -> API.SubscriptionRecord -> H.ComponentHTML Action () m
renderSubscriptionCard _idx sub =
  let catClass = " sub-cat-" <> sub.category
      urgencyClass = ""  -- TODO: highlight if next_due is within 7 days
      tierCls = if sub.amount >= 30.0 then " tier-regular" else " tier-small"
  in HH.div
    [ HP.class_ (H.ClassName ("project-card subscription-card" <> catClass <> tierCls <> urgencyClass)) ]
    [ HH.div [ HP.class_ (H.ClassName "card-header") ]
        [ HH.h3 [ HP.class_ (H.ClassName "card-title") ]
            [ HH.text sub.name ]
        , HH.div [ HP.class_ (H.ClassName "sub-amount") ]
            [ HH.text (show sub.amount <> " " <> sub.currency)
            , HH.span [ HP.class_ (H.ClassName "sub-frequency") ]
                [ HH.text ("/" <> freqAbbrev sub.frequency) ]
            ]
        ]
    , HH.div [ HP.class_ (H.ClassName "card-meta") ]
        [ HH.span [ HP.class_ (H.ClassName "sub-category") ]
            [ HH.text sub.category ]
        , if String.null sub.nextDue
            then HH.text ""
            else HH.span [ HP.class_ (H.ClassName "sub-next-due") ]
              [ HH.text ("due " <> String.take 10 sub.nextDue) ]
        ]
    , if String.null sub.notes
        then HH.text ""
        else HH.p [ HP.class_ (H.ClassName "card-description") ]
          [ HH.text sub.notes ]
    ]

freqAbbrev :: String -> String
freqAbbrev = case _ of
  "monthly"   -> "mo"
  "annual"    -> "yr"
  "quarterly" -> "qtr"
  "weekly"    -> "wk"
  _           -> "?"

-- =============================================================================
-- Project Card (Task 2: status dot + popover; Task 3: quick edit button)
-- =============================================================================

renderProjectCard :: forall m. State -> Int -> Project -> H.ComponentHTML Action () m
renderProjectCard state idx project =
  let isFocused = state.focusIndex == idx
      focusClass = if isFocused then " card-focused" else ""
      tier = pickTier idx project
      tierCls = " " <> tierClass tier
      coverCls = case project.coverUrl of
        Nothing -> ""
        Just _  -> " has-cover"
  in HH.div
    [ HP.class_ (H.ClassName ("project-card card-domain-" <> project.domain <> tierCls <> coverCls <> focusClass))
    , HE.onClick \_ -> SelectProject project.id
    ]
    [ HH.div [ HP.class_ (H.ClassName "card-header") ]
        [ HH.h3 [ HP.class_ (H.ClassName "card-title") ]
            [ HH.text project.name ]
        , HH.div [ HP.class_ (H.ClassName "card-header-controls") ]
            [ renderStatusControl project
            ]
        ]
    , HH.div [ HP.class_ (H.ClassName "card-meta") ]
        [ renderDomainLabel project.domain
        , case project.subdomain of
            Nothing -> HH.text ""
            Just sub -> HH.span [ HP.class_ (H.ClassName "card-subdomain") ]
              [ HH.text sub ]
        , renderCardPortBadges state project.id
        , case project.slug of
            Nothing -> HH.text ""
            Just s -> HH.span [ HP.class_ (H.ClassName "card-slug") ]
              [ HH.text s ]
        , renderCardBlogPill project.blogStatus
        ]
    , case project.description of
        Nothing -> HH.text ""
        Just desc -> HH.p [ HP.class_ (H.ClassName "card-description") ]
          [ HH.text (truncate 120 desc) ]
    , if Array.null project.tags
        then HH.text ""
        else HH.div [ HP.class_ (H.ClassName "card-tags") ]
          (map renderTag project.tags)
    -- Cover image (if any) goes last so it can absorb whatever vertical
    -- space is left after the text has laid out. It docks to the
    -- bottom-right of the card via CSS.
    , case project.coverUrl of
        Nothing -> HH.text ""
        Just url -> HH.div [ HP.class_ (H.ClassName "card-cover") ]
          [ HH.img
              [ HP.src url
              , HP.alt (project.name <> " screenshot")
              ]
          ]
    ]

-- | Port badges on cards — show every allocated port for this project as
-- | a small monospace chip. Projects with no servers render nothing.
renderCardPortBadges :: forall m. State -> Int -> H.ComponentHTML Action () m
renderCardPortBadges state projectId =
  let myServers = Array.filter (\s -> s.projectId == projectId) state.servers
      withPorts = Array.catMaybes (map (\s -> map (Tuple s.role) s.port) myServers)
  in if Array.null withPorts
    then HH.text ""
    else HH.span [ HP.class_ (H.ClassName "card-ports") ]
      (map renderPortChip withPorts)
  where
  renderPortChip :: Tuple String Int -> H.ComponentHTML Action () m
  renderPortChip (Tuple role port) =
    HH.span
      [ HP.class_ (H.ClassName "port-chip")
      , HP.title (role <> " :" <> show port)
      ]
      [ HH.text (":" <> show port) ]

-- | Render a tag span. Option-click filters by that tag.
renderTag :: forall m. String -> H.ComponentHTML Action () m
renderTag t =
  HH.span
    [ HP.class_ (H.ClassName "tag")
    , HP.title "Option-click to filter by this tag"
    , HE.onClick \e -> TagClick t e
    ]
    [ HH.text t ]

-- | Traffic light status control: always-visible row of 7 colored dots + label
renderStatusControl :: forall m. Project -> H.ComponentHTML Action () m
renderStatusControl project =
  HH.div [ HP.class_ (H.ClassName "status-lights") ]
    ( map (renderStatusLight project) allStatuses
      <> [ HH.span [ HP.class_ (H.ClassName "status-lights-label") ]
             [ HH.text (statusLabel project.status) ]
         ]
    )

renderStatusLight :: forall m. Project -> Status -> H.ComponentHTML Action () m
renderStatusLight project status =
  let statusStr = statusToString status
      isCurrent = project.status == status
      lightClass = "status-light status-light-" <> statusStr
        <> (if isCurrent then " current" else "")
  in HH.button
    [ HP.class_ (H.ClassName lightClass)
    , HP.title (statusLabel status)
    , HP.disabled isCurrent
    , HE.onClick \e -> QuickStatusChange project.id status e
    ]
    []

renderDomainLabel :: forall m. String -> H.ComponentHTML Action () m
renderDomainLabel domain =
  HH.span [ HP.class_ (H.ClassName ("domain-label domain-" <> domain)) ]
    [ HH.text domain ]

-- | Compact pill on a Register card showing the project's blog-post
-- | classification. Nothing (unclassified) renders nothing — don't want
-- | to crowd every card with an "unclassified" label. The other four
-- | states render a tiny coloured pill with the label.
renderCardBlogPill :: forall m. Maybe BlogStatus -> H.ComponentHTML Action () m
renderCardBlogPill = case _ of
  Nothing -> HH.text ""
  Just bs ->
    HH.span
      [ HP.class_ (H.ClassName ("card-blog-pill blog-pill-" <> blogStatusToString bs))
      , HP.title ("Blog post: " <> blogStatusLabel bs)
      ]
      [ HH.text (blogStatusLabel bs) ]

renderLoading :: forall m. H.ComponentHTML Action () m
renderLoading =
  HH.div [ HP.class_ (H.ClassName "loading") ]
    [ HH.text "Loading..." ]

-- =============================================================================
-- Shared detail helpers (used by the Dossier view)
-- =============================================================================

renderServerRow :: forall m. Server -> H.ComponentHTML Action () m
renderServerRow server =
  HH.div [ HP.class_ (H.ClassName "server-row") ]
    [ HH.span [ HP.class_ (H.ClassName "server-role") ]
        [ HH.text server.role ]
    , HH.span [ HP.class_ (H.ClassName "server-port") ]
        [ HH.text (case server.port of
            Just p -> ":" <> show p
            Nothing -> "(no port)") ]
    , case server.url of
        Nothing -> HH.text ""
        Just u -> HH.a
          [ HP.class_ (H.ClassName "server-link")
          , HP.href u
          , HP.target "_blank"
          , HP.title "Open in new tab"
          ]
          [ HH.text "↗" ]
    , HH.span [ HP.class_ (H.ClassName "server-desc") ]
        [ HH.text (fromMaybe "" server.description) ]
    , HH.button
        [ HP.class_ (H.ClassName "btn btn-back server-delete")
        , HE.onClick \_ -> DeleteServerAction server.id
        , HP.title "Delete this server"
        ]
        [ HH.text "×" ]
    ]

-- | Render image previews and links for attachments.
-- | Walk up the parent chain, returning [parent, grandparent, great-grandparent, ...]
-- | Stops when an ancestor is not in the projects array (out of view) or chain is exhausted.
collectAncestors :: Array Project -> Maybe Int -> Array Project
collectAncestors projects = go []
  where
  go acc Nothing = acc
  go acc (Just pid) = case Array.find (\p -> p.id == pid) projects of
    Nothing -> acc
    Just p -> go (Array.snoc acc p) p.parentId

-- | List children of this project, if any. Click to navigate.
-- | Always show the "+ Add child" affordance so any project can be split.
-- =============================================================================
-- The Dossier — click-to-edit project page
-- =============================================================================
-- | A project page modeled on a WSJ feature story: narrow text column on the
-- | left (description, notes) with a wide marginalia column on the right
-- | carrying all metadata. No edit-mode; every field is click-to-edit in
-- | place. Extends the index's broadsheet grammar to a detail spread.
-- |
-- | Orthogonal to this view, other domains may eventually get different
-- | renderings (e.g. a Magazine view for ideaboards). The dispatch happens
-- | at the top-level render via state.detailViewKind.

renderDossier :: forall m. State -> ProjectDetail -> H.ComponentHTML Action () m
renderDossier state detail =
  HH.div [ HP.class_ (H.ClassName "dossier") ]
    [ renderDossierTopStrip detail
    , HH.div [ HP.class_ (H.ClassName "dossier-page") ]
        [ HH.section [ HP.class_ (H.ClassName "dossier-main") ]
            [ renderDossierBreadcrumb state detail
            , renderDossierTitle state detail
            , HH.div [ HP.class_ (H.ClassName "dossier-rule") ] []
            , renderDossierDescription state detail
            , renderDossierNotes state detail
            ]
        , HH.aside [ HP.class_ (H.ClassName "dossier-marginalia") ]
            [ marginaliaSection "Status" (renderStatusEditor state detail)
            , marginaliaSection "Domain" (renderDomainEditor state detail)
            , marginaliaSection "Identifier" (renderIdentifierBlock detail)
            , marginaliaSection "Tags" (renderTagsEditor state detail)
            , marginaliaSection "Blog" (renderBlogEditor state detail)
            , marginaliaSection "Parent" (renderParentBlock state detail)
            , marginaliaSection "Children" (renderChildrenBlock state detail)
            , marginaliaSection "History" (renderHistoryBlock detail)
            , marginaliaSection "External" (renderExternalEditor state detail)
            , marginaliaSection "Servers" (renderServersBlock state detail)
            , marginaliaSection "Dependencies" (renderDependenciesBlock detail)
            , marginaliaSection "Attachments" (renderAttachmentsBlock detail)
            ]
        ]
    ]

-- | Top navigation strip: ← prev · view switcher · close ×
renderDossierTopStrip :: forall m. ProjectDetail -> H.ComponentHTML Action () m
renderDossierTopStrip detail =
  let currentKind = parseViewKind detail.preferredView
  in HH.div [ HP.class_ (H.ClassName "dossier-top") ]
    [ HH.div [ HP.class_ (H.ClassName "dossier-top-nav") ]
        [ HH.button
            [ HP.class_ (H.ClassName "dossier-nav-btn")
            , HE.onClick \_ -> PrevProject
            , HP.title "Previous project (k)"
            ]
            [ HH.text "‹ prev" ]
        , HH.span [ HP.class_ (H.ClassName "dossier-page-num") ]
            [ HH.text ("No. " <> show detail.id) ]
        , HH.button
            [ HP.class_ (H.ClassName "dossier-nav-btn")
            , HE.onClick \_ -> NextProject
            , HP.title "Next project (j)"
            ]
            [ HH.text "next ›" ]
        ]
    , renderViewSwitcher currentKind
    , HH.button
        [ HP.class_ (H.ClassName "dossier-close")
        , HE.onClick \_ -> CloseDetail
        , HP.title "Close (Esc)"
        ]
        [ HH.text "close ×" ]
    ]

-- | The dossier / magazine view switcher. Renders both view names as
-- | small-caps labels with the current one underlined. Clicking the
-- | inactive one dispatches DossierSetView which persists the choice.
renderViewSwitcher :: forall m. DetailViewKind -> H.ComponentHTML Action () m
renderViewSwitcher current =
  HH.div [ HP.class_ (H.ClassName "view-switcher") ]
    [ HH.span [ HP.class_ (H.ClassName "view-switcher-label") ]
        [ HH.text "view" ]
    , HH.button
        [ HP.class_ (H.ClassName
            ("view-switcher-btn" <>
              if current == DossierView then " view-switcher-active" else ""))
        , HE.onClick \_ -> DossierSetView DossierView
        , HP.title "Dossier view: WSJ-style facts and figures"
        ]
        [ HH.text "dossier" ]
    , HH.span [ HP.class_ (H.ClassName "view-switcher-sep") ] [ HH.text "·" ]
    , HH.button
        [ HP.class_ (H.ClassName
            ("view-switcher-btn" <>
              if current == MagazineView then " view-switcher-active" else ""))
        , HE.onClick \_ -> DossierSetView MagazineView
        , HP.title "Magazine view: visual, Pinterest-ish for ideaboards"
        ]
        [ HH.text "magazine" ]
    ]

-- | Breadcrumb pills above the title, showing parent chain. Click an
-- | ancestor to filter the Register down to its descendants.
renderDossierBreadcrumb :: forall m. State -> ProjectDetail -> H.ComponentHTML Action () m
renderDossierBreadcrumb state detail =
  let ancestors = collectAncestors state.allProjects detail.parentId
      reversedAncestors = Array.reverse ancestors  -- top-down: oldest first
  in if Array.null ancestors
    then HH.text ""
    else HH.nav [ HP.class_ (H.ClassName "dossier-breadcrumb") ]
      (Array.intercalate [ HH.span [ HP.class_ (H.ClassName "dossier-breadcrumb-sep") ] [ HH.text " › " ] ]
        (map (\p -> [ HH.span
              [ HP.class_ (H.ClassName "dossier-breadcrumb-crumb")
              , HE.onClick \_ -> SelectProject p.id
              ]
              [ HH.text p.name ]
            ]) reversedAncestors))

-- | Click-to-edit project title. Delegates to the existing rename flow,
-- | which already handles the "also rename source directory" sidecar.
renderDossierTitle :: forall m. State -> ProjectDetail -> H.ComponentHTML Action () m
renderDossierTitle state detail = case state.renameOpen of
  Just pid | pid == detail.id ->
    let hasDirSource = case detail.sourcePath of
          Just sp -> not (String.null sp)
          Nothing -> false
    in HH.div [ HP.class_ (H.ClassName "dossier-title-edit") ]
      [ HH.form
          [ HE.onSubmit \_ -> SubmitRename detail.id ]
          [ HH.input
              [ HP.class_ (H.ClassName "dossier-title-input")
              , HP.type_ HP.InputText
              , HP.value state.renameValue
              , HP.autofocus true
              , HE.onValueInput SetRenameValue
              ]
          ]
      , if hasDirSource
          then HH.label [ HP.class_ (H.ClassName "dossier-title-dirtoggle") ]
            [ HH.input
                [ HP.type_ HP.InputCheckbox
                , HP.checked state.renameDirectory
                , HE.onClick \_ -> ToggleRenameDirectory
                ]
            , HH.text " also rename source directory"
            ]
          else HH.text ""
      ]
  _ ->
    HH.h1
      [ HP.class_ (H.ClassName "dossier-title")
      , HE.onClick \_ -> StartRename detail.id detail.name
      , HP.title "Click to rename"
      ]
      [ HH.text detail.name ]

-- | Click-to-edit description. Appears in the main text column, the heart
-- | of the dossier. Uses a textarea when editing; commits on blur.
renderDossierDescription :: forall m. State -> ProjectDetail -> H.ComponentHTML Action () m
renderDossierDescription state detail =
  case state.dossierEditField of
    Just FDescription ->
      HH.div [ HP.class_ (H.ClassName "dossier-description-edit") ]
        [ HH.textarea
            [ HP.class_ (H.ClassName "dossier-description-input")
            , HP.value state.dossierEditValue
            , HP.autofocus true
            , HP.rows 8
            , HP.placeholder "What is this project?"
            , HE.onValueInput DossierSetEditValue
            , HE.onBlur \_ -> DossierCommitEdit
            ]
        , HH.div [ HP.class_ (H.ClassName "dossier-edit-hint") ]
            [ HH.text "Blur to save · Esc to cancel" ]
        ]
    _ ->
      let currentDesc = fromMaybe "" detail.description
      in HH.div
        [ HP.class_ (H.ClassName "dossier-description editable")
        , HE.onClick \_ -> DossierStartEdit FDescription currentDesc
        , HP.title "Click to edit description"
        ]
        [ if String.null currentDesc
            then HH.p [ HP.class_ (H.ClassName "dossier-description-empty") ]
              [ HH.text "No description. Click to write one." ]
            else HH.p_ [ HH.text currentDesc ]
        ]

-- | Note stream: numbered list of existing notes, plus an append-only
-- | inline composer at the bottom. Notes are immutable once saved.
renderDossierNotes :: forall m. State -> ProjectDetail -> H.ComponentHTML Action () m
renderDossierNotes state detail =
  HH.section [ HP.class_ (H.ClassName "dossier-notes") ]
    [ HH.h3 [ HP.class_ (H.ClassName "dossier-section-label") ]
        [ HH.text "§ notes" ]
    , HH.div [ HP.class_ (H.ClassName "dossier-notes-rule") ] []
    , if Array.null detail.notes
        then HH.p [ HP.class_ (H.ClassName "dossier-notes-empty") ]
          [ HH.text "No notes yet." ]
        else HH.ol [ HP.class_ (H.ClassName "dossier-notes-list") ]
          (map renderDossierNote detail.notes)
    , renderDossierNoteComposer state
    ]

renderDossierNote :: forall m.
  { id :: Int, content :: String, author :: Maybe String, createdAt :: Maybe String }
  -> H.ComponentHTML Action () m
renderDossierNote note =
  HH.li [ HP.class_ (H.ClassName "dossier-note") ]
    [ HH.div [ HP.class_ (H.ClassName "dossier-note-meta") ]
        [ case note.createdAt of
            Just d -> HH.span [ HP.class_ (H.ClassName "dossier-note-date") ]
              [ HH.text (String.take 10 d) ]
            Nothing -> HH.text ""
        , case note.author of
            Just a -> HH.span [ HP.class_ (H.ClassName "dossier-note-author") ]
              [ HH.text (" · " <> a) ]
            Nothing -> HH.text ""
        ]
    , HH.p [ HP.class_ (H.ClassName "dossier-note-content") ]
        [ HH.text note.content ]
    ]

renderDossierNoteComposer :: forall m. State -> H.ComponentHTML Action () m
renderDossierNoteComposer state =
  if state.dossierNoteOpen
    then HH.div [ HP.class_ (H.ClassName "dossier-note-composer") ]
      [ HH.textarea
          [ HP.class_ (H.ClassName "dossier-note-input")
          , HP.id "note-input"
          , HP.value state.dossierNoteDraft
          , HP.placeholder "Write a note. ⌘+Enter to save, Esc to cancel."
          , HP.rows 4
          , HP.autofocus true
          , HE.onValueInput DossierSetNote
          ]
      , HH.div [ HP.class_ (H.ClassName "dossier-note-composer-actions") ]
          [ HH.button
              [ HP.class_ (H.ClassName "dossier-btn-ghost")
              , HE.onClick \_ -> DossierCancelNote
              ]
              [ HH.text "cancel" ]
          , HH.button
              [ HP.class_ (H.ClassName "dossier-btn-primary")
              , HE.onClick \_ -> DossierSubmitNote
              , HP.disabled (String.null (String.trim state.dossierNoteDraft))
              ]
              [ HH.text "add note" ]
          ]
      ]
    else HH.button
      [ HP.class_ (H.ClassName "dossier-note-addbtn")
      , HE.onClick \_ -> DossierOpenNote
      ]
      [ HH.text "+ add note" ]

-- ---- Marginalia helpers ----

-- | Render one labeled block in the right marginalia column.
marginaliaSection :: forall m. String -> H.ComponentHTML Action () m -> H.ComponentHTML Action () m
marginaliaSection label body =
  HH.section [ HP.class_ (H.ClassName "marginalia-section") ]
    [ HH.h4 [ HP.class_ (H.ClassName "marginalia-label") ] [ HH.text label ]
    , HH.div [ HP.class_ (H.ClassName "marginalia-body") ] [ body ]
    ]

-- | Status editor: shows the current status, clicking reveals a row of
-- | valid-transition pills (enforces the lifecycle DAG via nextStatuses).
renderStatusEditor :: forall m. State -> ProjectDetail -> H.ComponentHTML Action () m
renderStatusEditor _state detail =
  HH.div [ HP.class_ (H.ClassName "status-editor") ]
    [ HH.span
        [ HP.class_ (H.ClassName ("status-current status-" <> statusToString detail.status))
        ]
        [ HH.text (statusLabel detail.status) ]
    , let opts = nextStatuses detail.status
      in if Array.null opts
        then HH.div [ HP.class_ (H.ClassName "status-transitions-empty") ]
          [ HH.text "terminal" ]
        else HH.div [ HP.class_ (H.ClassName "status-transitions") ]
          ( [ HH.span [ HP.class_ (H.ClassName "status-arrow") ] [ HH.text "→ " ] ]
          <> map (\s -> HH.button
              [ HP.class_ (H.ClassName "status-transition-pill")
              , HE.onClick (\me -> QuickStatusChange detail.id s me)
              , HP.title ("Transition to " <> statusLabel s)
              ]
              [ HH.text (statusLabel s) ]) opts
          )
    ]

-- | Domain editor: click to open a dropdown of all domains. Selecting one
-- | commits immediately via PUT.
renderDomainEditor :: forall m. State -> ProjectDetail -> H.ComponentHTML Action () m
renderDomainEditor state detail =
  if state.dossierDomainOpen
    then HH.div [ HP.class_ (H.ClassName "domain-editor-open") ]
      (map (\d -> HH.button
          [ HP.class_ (H.ClassName ("domain-option domain-" <> d))
          , HE.onClick \_ -> DossierPickDomain d
          ]
          [ HH.text d ]) allDomains)
    else HH.span
      [ HP.class_ (H.ClassName ("domain-current editable domain-" <> detail.domain))
      , HE.onClick \_ -> DossierOpenDomain
      , HP.title "Click to change domain"
      ]
      [ HH.text detail.domain ]

allDomains :: Array String
allDomains =
  [ "programming", "music", "house", "woodworking", "garden", "infrastructure" ]

-- | Identifier block: slug (monospace, immutable) + id.
renderIdentifierBlock :: forall m. ProjectDetail -> H.ComponentHTML Action () m
renderIdentifierBlock detail =
  HH.div [ HP.class_ (H.ClassName "identifier-block") ]
    [ case detail.slug of
        Just s -> HH.span [ HP.class_ (H.ClassName "identifier-slug") ]
          [ HH.text s ]
        Nothing -> HH.text ""
    , HH.span [ HP.class_ (H.ClassName "identifier-id") ]
        [ HH.text ("id " <> show detail.id) ]
    , case detail.subdomain of
        Just sd | not (String.null sd) -> HH.span
          [ HP.class_ (H.ClassName "identifier-subdomain editable")
          , HE.onClick \_ -> DossierStartEdit FSubdomain sd
          ]
          [ HH.text sd ]
        _ -> HH.text ""
    ]

-- | Tags editor: existing tags + "+ add" to open an inline input.
renderTagsEditor :: forall m. State -> ProjectDetail -> H.ComponentHTML Action () m
renderTagsEditor state detail =
  HH.div [ HP.class_ (H.ClassName "tags-editor") ]
    [ if Array.null detail.tags
        then HH.span [ HP.class_ (H.ClassName "tags-empty") ] [ HH.text "—" ]
        else HH.div [ HP.class_ (H.ClassName "tag-pill-row") ]
          (map (\t -> HH.span [ HP.class_ (H.ClassName "tag-pill") ] [ HH.text t ]) detail.tags)
    , if state.dossierTagOpen
        then HH.form
          [ HP.class_ (H.ClassName "tag-add-form")
          , HE.onSubmit \_ -> DossierSubmitTag
          ]
          [ HH.input
              [ HP.class_ (H.ClassName "tag-add-input")
              , HP.type_ HP.InputText
              , HP.value state.dossierTagDraft
              , HP.placeholder "new tag"
              , HP.autofocus true
              , HE.onValueInput DossierSetTag
              ]
          ]
        else HH.button
          [ HP.class_ (H.ClassName "tags-add-btn")
          , HE.onClick \_ -> DossierOpenTag
          ]
          [ HH.text "+ add tag" ]
    ]

-- | Blog-post editor: row of 4 state buttons (NotNeeded/Wanted/Drafted/
-- | Published) plus a click-to-edit markdown textarea that only appears
-- | when the status is Drafted or Published. The buttons highlight the
-- | current state; clicking a different button immediately PUTs the new
-- | status to the server via SetBlogStatus.
renderBlogEditor :: forall m. State -> ProjectDetail -> H.ComponentHTML Action () m
renderBlogEditor state detail =
  HH.div [ HP.class_ (H.ClassName "blog-editor") ]
    [ HH.div [ HP.class_ (H.ClassName "blog-status-row") ]
        (map (renderBlogStatusButton detail.blogStatus) allBlogStatuses)
    , case detail.blogStatus of
        Just BlogDrafted   -> renderBlogContentEditor state detail
        Just BlogPublished -> renderBlogContentEditor state detail
        _                  -> HH.text ""
    ]

renderBlogStatusButton :: forall m. Maybe BlogStatus -> BlogStatus -> H.ComponentHTML Action () m
renderBlogStatusButton currentStatus status =
  let isCurrent = currentStatus == Just status
      btnClass = "blog-status-btn blog-status-" <> blogStatusToString status
        <> (if isCurrent then " current" else "")
  in HH.button
    [ HP.class_ (H.ClassName btnClass)
    , HP.title (blogStatusLabel status)
    , HP.disabled isCurrent
    , HE.onClick \e -> SetBlogStatus (Just status) e
    ]
    [ HH.text (blogStatusLabel status) ]

renderBlogContentEditor :: forall m. State -> ProjectDetail -> H.ComponentHTML Action () m
renderBlogContentEditor state detail =
  case state.dossierEditField of
    Just FBlogContent ->
      HH.div [ HP.class_ (H.ClassName "blog-content-edit") ]
        [ HH.textarea
            [ HP.class_ (H.ClassName "blog-content-input")
            , HP.value state.dossierEditValue
            , HP.autofocus true
            , HP.rows 12
            , HP.placeholder "# Heading\n\nMarkdown body…"
            , HE.onValueInput DossierSetEditValue
            , HE.onBlur \_ -> DossierCommitEdit
            ]
        , HH.div [ HP.class_ (H.ClassName "dossier-edit-hint") ]
            [ HH.text "Blur to save · Esc to cancel" ]
        ]
    _ ->
      let currentContent = fromMaybe "" detail.blogContent
      in HH.div
        [ HP.class_ (H.ClassName "blog-content editable")
        , HE.onClick \_ -> DossierStartEdit FBlogContent currentContent
        , HP.title "Click to edit blog post"
        ]
        [ if String.null currentContent
            then HH.p [ HP.class_ (H.ClassName "blog-content-empty") ]
              [ HH.text "No draft yet. Click to start writing." ]
            else HH.pre [ HP.class_ (H.ClassName "blog-content-body") ]
              [ HH.text currentContent ]
        ]

-- | Parent block: shows the parent project (clickable) or "(none)".
renderParentBlock :: forall m. State -> ProjectDetail -> H.ComponentHTML Action () m
renderParentBlock state detail =
  case detail.parentId of
    Nothing -> HH.span [ HP.class_ (H.ClassName "marginalia-muted") ] [ HH.text "(none)" ]
    Just pid -> case Array.find (\p -> p.id == pid) state.allProjects of
      Nothing -> HH.span [ HP.class_ (H.ClassName "marginalia-muted") ]
        [ HH.text ("id " <> show pid) ]
      Just p -> HH.span
        [ HP.class_ (H.ClassName "parent-link")
        , HE.onClick \_ -> SelectProject p.id
        ]
        [ HH.text ("↑ " <> p.name) ]

-- | Children block: lists child projects with a + button for adding more.
renderChildrenBlock :: forall m. State -> ProjectDetail -> H.ComponentHTML Action () m
renderChildrenBlock state detail =
  let children = Array.filter (\p -> p.parentId == Just detail.id) state.allProjects
  in HH.div [ HP.class_ (H.ClassName "children-block") ]
    [ if Array.null children
        then HH.span [ HP.class_ (H.ClassName "marginalia-muted") ] [ HH.text "(none)" ]
        else HH.ul [ HP.class_ (H.ClassName "children-list-marg") ]
          (map (\c -> HH.li_
            [ HH.span
                [ HP.class_ (H.ClassName "child-link")
                , HE.onClick \_ -> SelectProject c.id
                ]
                [ HH.text c.name ]
            ]) children)
    , case state.addChildOpen of
        Just pid | pid == detail.id -> HH.form
          [ HP.class_ (H.ClassName "add-child-form-marg")
          , HE.onSubmit \_ -> SubmitAddChild detail.id
          ]
          [ HH.input
              [ HP.class_ (H.ClassName "add-child-input")
              , HP.type_ HP.InputText
              , HP.value state.addChildName
              , HP.placeholder "new child name"
              , HP.autofocus true
              , HE.onValueInput SetAddChildName
              ]
          ]
        _ -> HH.button
          [ HP.class_ (H.ClassName "children-add-btn")
          , HE.onClick \_ -> OpenAddChild detail.id
          ]
          [ HH.text "+ add child" ]
    ]

-- | History block: created + updated dates in ISO format.
renderHistoryBlock :: forall m. ProjectDetail -> H.ComponentHTML Action () m
renderHistoryBlock detail =
  HH.div [ HP.class_ (H.ClassName "history-block") ]
    [ case detail.createdAt of
        Just c -> HH.div_
          [ HH.span [ HP.class_ (H.ClassName "history-label") ] [ HH.text "created " ]
          , HH.span [ HP.class_ (H.ClassName "history-date") ] [ HH.text (String.take 10 c) ]
          ]
        Nothing -> HH.text ""
    , case detail.updatedAt of
        Just u -> HH.div_
          [ HH.span [ HP.class_ (H.ClassName "history-label") ] [ HH.text "updated " ]
          , HH.span [ HP.class_ (H.ClassName "history-date") ] [ HH.text (String.take 10 u) ]
          ]
        Nothing -> HH.text ""
    ]

-- | External links: repo, url, source path. Each click-to-edit.
renderExternalEditor :: forall m. State -> ProjectDetail -> H.ComponentHTML Action () m
renderExternalEditor state detail =
  HH.dl [ HP.class_ (H.ClassName "external-dl") ]
    [ renderExternalField state FRepo "repo" detail.repo
    , renderExternalField state FSourceUrl "url" detail.sourceUrl
    , renderExternalField state FSourcePath "path" detail.sourcePath
    ]

renderExternalField
  :: forall m. State -> EditableField -> String -> Maybe String
  -> H.ComponentHTML Action () m
renderExternalField state field label mValue =
  let currentValue = fromMaybe "" mValue
  in HH.div [ HP.class_ (H.ClassName "external-row") ]
    [ HH.dt [ HP.class_ (H.ClassName "external-key") ] [ HH.text label ]
    , HH.dd [ HP.class_ (H.ClassName "external-val") ]
        [ case state.dossierEditField of
            Just f | f == field ->
              HH.form
                [ HE.onSubmit \_ -> DossierCommitEdit ]
                [ HH.input
                    [ HP.class_ (H.ClassName "external-input")
                    , HP.type_ HP.InputText
                    , HP.value state.dossierEditValue
                    , HP.autofocus true
                    , HE.onValueInput DossierSetEditValue
                    , HE.onBlur \_ -> DossierCommitEdit
                    ]
                ]
            _ ->
              if String.null currentValue
                then HH.span
                  [ HP.class_ (H.ClassName "external-empty editable")
                  , HE.onClick \_ -> DossierStartEdit field currentValue
                  ]
                  [ HH.text "—" ]
                else HH.span
                  [ HP.class_ (H.ClassName "external-value editable")
                  , HE.onClick \_ -> DossierStartEdit field currentValue
                  , HP.title ("Click to edit " <> label)
                  ]
                  [ HH.text currentValue ]
        ]
    ]

-- | Compact servers list in the marginalia column. Reuses the server-row
-- | rendering from the old detail panel, which already has a row layout.
renderServersBlock :: forall m. State -> ProjectDetail -> H.ComponentHTML Action () m
renderServersBlock state detail =
  let myServers = Array.filter (\s -> s.projectId == detail.id) state.servers
  in if Array.null myServers
    then HH.span [ HP.class_ (H.ClassName "marginalia-muted") ] [ HH.text "(none)" ]
    else HH.div [ HP.class_ (H.ClassName "servers-block") ]
      (map renderServerRow myServers)

-- | Dependencies block: inbound and outbound references as lists.
renderDependenciesBlock :: forall m. ProjectDetail -> H.ComponentHTML Action () m
renderDependenciesBlock detail =
  let blocking = detail.dependencies.blocking
      blockedBy = detail.dependencies.blockedBy
  in if Array.null blocking && Array.null blockedBy
    then HH.span [ HP.class_ (H.ClassName "marginalia-muted") ] [ HH.text "(none)" ]
    else HH.div [ HP.class_ (H.ClassName "deps-block") ]
      [ if Array.null blockedBy then HH.text ""
        else HH.div_
          [ HH.span [ HP.class_ (H.ClassName "deps-sublabel") ] [ HH.text "blocked by" ]
          , HH.ul_
            (map (\d -> HH.li_
              [ HH.span
                  [ HP.class_ (H.ClassName "dep-link")
                  , HE.onClick \_ -> SelectProject d.projectId
                  ]
                  [ HH.text d.projectName ]
              ]) blockedBy)
          ]
      , if Array.null blocking then HH.text ""
        else HH.div_
          [ HH.span [ HP.class_ (H.ClassName "deps-sublabel") ] [ HH.text "blocking" ]
          , HH.ul_
            (map (\d -> HH.li_
              [ HH.span
                  [ HP.class_ (H.ClassName "dep-link")
                  , HE.onClick \_ -> SelectProject d.projectId
                  ]
                  [ HH.text d.projectName ]
              ]) blocking)
          ]
      ]

-- | Attachments in the marginalia column: filenames as links.
renderAttachmentsBlock :: forall m. ProjectDetail -> H.ComponentHTML Action () m
renderAttachmentsBlock detail =
  if Array.null detail.attachments
    then HH.span [ HP.class_ (H.ClassName "marginalia-muted") ] [ HH.text "(none)" ]
    else HH.ul [ HP.class_ (H.ClassName "attachments-marg-list") ]
      (map renderAttachmentMargRow detail.attachments)

renderAttachmentMargRow :: forall m. Attachment -> H.ComponentHTML Action () m
renderAttachmentMargRow att =
  HH.li [ HP.class_ (H.ClassName "attachment-marg-row") ]
    [ case att.url of
        Nothing -> HH.span [ HP.class_ (H.ClassName "attachment-marg-filename") ]
          [ HH.text ("📎 " <> att.filename) ]
        Just url -> HH.a
          [ HP.class_ (H.ClassName "attachment-marg-filename")
          , HP.href url
          , HP.target "_blank"
          ]
          [ HH.text ("📎 " <> att.filename) ]
    ]

-- =============================================================================
-- The Magazine — alternate detail view for image-heavy ideaboard projects
-- =============================================================================
-- | For projects where images are the primary content (house remodels,
-- | woodworking inspiration, garden plans, furniture clippings) the dossier's
-- | narrow text column is the wrong shape. Magazine view:
-- |   - drops the right marginalia rail
-- |   - features image attachments as a Pinterest-ish grid
-- |   - compresses all metadata into a single horizontal strip at the bottom
-- |   - keeps the notes stream below the images
-- |
-- | Text fields are still click-to-edit just as in the dossier — the
-- | editing state machine is shared. Only the layout is different.

renderMagazine :: forall m. State -> ProjectDetail -> H.ComponentHTML Action () m
renderMagazine state detail =
  HH.div [ HP.class_ (H.ClassName "magazine") ]
    [ renderMagazineTopStrip detail
    , HH.div [ HP.class_ (H.ClassName "magazine-page") ]
        [ renderDossierBreadcrumb state detail
        , renderMagazineTitle state detail
        , HH.div [ HP.class_ (H.ClassName "magazine-rule") ] []
        , renderMagazineDescription state detail
        , renderMagazineAttachments detail
        , renderMagazineNotes state detail
        , renderMagazineMetaStrip state detail
        ]
    ]

-- | Top strip for magazine view. Same shape as the dossier's, using the
-- | same view switcher so you can flip back.
renderMagazineTopStrip :: forall m. ProjectDetail -> H.ComponentHTML Action () m
renderMagazineTopStrip detail =
  let currentKind = parseViewKind detail.preferredView
  in HH.div [ HP.class_ (H.ClassName "dossier-top magazine-top") ]
    [ HH.div [ HP.class_ (H.ClassName "dossier-top-nav") ]
        [ HH.button
            [ HP.class_ (H.ClassName "dossier-nav-btn")
            , HE.onClick \_ -> PrevProject
            ]
            [ HH.text "‹ prev" ]
        , HH.span [ HP.class_ (H.ClassName "dossier-page-num") ]
            [ HH.text ("No. " <> show detail.id) ]
        , HH.button
            [ HP.class_ (H.ClassName "dossier-nav-btn")
            , HE.onClick \_ -> NextProject
            ]
            [ HH.text "next ›" ]
        ]
    , renderViewSwitcher currentKind
    , HH.button
        [ HP.class_ (H.ClassName "dossier-close")
        , HE.onClick \_ -> CloseDetail
        ]
        [ HH.text "close ×" ]
    ]

-- | Magazine title: larger and centered rather than left-aligned. Reuses
-- | the dossier's rename flow.
renderMagazineTitle :: forall m. State -> ProjectDetail -> H.ComponentHTML Action () m
renderMagazineTitle state detail = case state.renameOpen of
  Just pid | pid == detail.id ->
    HH.div [ HP.class_ (H.ClassName "magazine-title-edit") ]
      [ HH.form [ HE.onSubmit \_ -> SubmitRename detail.id ]
          [ HH.input
              [ HP.class_ (H.ClassName "magazine-title-input")
              , HP.type_ HP.InputText
              , HP.value state.renameValue
              , HP.autofocus true
              , HE.onValueInput SetRenameValue
              ]
          ]
      ]
  _ ->
    HH.h1
      [ HP.class_ (H.ClassName "magazine-title")
      , HE.onClick \_ -> StartRename detail.id detail.name
      , HP.title "Click to rename"
      ]
      [ HH.text detail.name ]

-- | Magazine description: wider column than the dossier, centered.
renderMagazineDescription :: forall m. State -> ProjectDetail -> H.ComponentHTML Action () m
renderMagazineDescription state detail =
  case state.dossierEditField of
    Just FDescription ->
      HH.div [ HP.class_ (H.ClassName "magazine-description-edit") ]
        [ HH.textarea
            [ HP.class_ (H.ClassName "magazine-description-input")
            , HP.value state.dossierEditValue
            , HP.autofocus true
            , HP.rows 6
            , HE.onValueInput DossierSetEditValue
            , HE.onBlur \_ -> DossierCommitEdit
            ]
        ]
    _ ->
      let currentDesc = fromMaybe "" detail.description
      in HH.div
        [ HP.class_ (H.ClassName "magazine-description editable")
        , HE.onClick \_ -> DossierStartEdit FDescription currentDesc
        ]
        [ if String.null currentDesc
            then HH.p [ HP.class_ (H.ClassName "magazine-description-empty") ]
              [ HH.text "Click to write a description." ]
            else HH.p_ [ HH.text currentDesc ]
        ]

-- | Pinterest-style image grid. Non-image attachments render as small
-- | file chips underneath the grid.
renderMagazineAttachments :: forall m. ProjectDetail -> H.ComponentHTML Action () m
renderMagazineAttachments detail =
  let images = Array.filter isImageAttachment detail.attachments
      others = Array.filter (not <<< isImageAttachment) detail.attachments
  in if Array.null detail.attachments
    then HH.div [ HP.class_ (H.ClassName "magazine-attachments-empty") ]
      [ HH.p [ HP.class_ (H.ClassName "text-muted") ]
          [ HH.text "No images or attachments yet." ]
      ]
    else HH.div [ HP.class_ (H.ClassName "magazine-attachments") ]
      [ if Array.null images then HH.text ""
        else HH.div [ HP.class_ (H.ClassName "magazine-image-grid") ]
          (map renderMagazineImage images)
      , if Array.null others then HH.text ""
        else HH.div [ HP.class_ (H.ClassName "magazine-file-row") ]
          (map renderMagazineFileChip others)
      ]

isImageAttachment :: Attachment -> Boolean
isImageAttachment att = case att.mimeType of
  Just mt -> String.take 6 mt == "image/"
  Nothing -> false

renderMagazineImage :: forall m. Attachment -> H.ComponentHTML Action () m
renderMagazineImage att = case att.url of
  Nothing -> HH.text ""
  Just url -> HH.a
    [ HP.class_ (H.ClassName "magazine-image-tile")
    , HP.href url
    , HP.target "_blank"
    , HP.title (fromMaybe att.filename att.description)
    ]
    [ HH.img
        [ HP.src url
        , HP.alt (fromMaybe att.filename att.description)
        ]
    ]

renderMagazineFileChip :: forall m. Attachment -> H.ComponentHTML Action () m
renderMagazineFileChip att =
  case att.url of
    Nothing -> HH.span [ HP.class_ (H.ClassName "magazine-file-chip") ]
      [ HH.text ("📎 " <> att.filename) ]
    Just url -> HH.a
      [ HP.class_ (H.ClassName "magazine-file-chip")
      , HP.href url
      , HP.target "_blank"
      ]
      [ HH.text ("📎 " <> att.filename) ]

-- | Notes in magazine view: same stream as dossier, lightly restyled.
renderMagazineNotes :: forall m. State -> ProjectDetail -> H.ComponentHTML Action () m
renderMagazineNotes state detail =
  HH.section [ HP.class_ (H.ClassName "magazine-notes") ]
    [ HH.h3 [ HP.class_ (H.ClassName "dossier-section-label") ]
        [ HH.text "§ notes" ]
    , HH.div [ HP.class_ (H.ClassName "dossier-notes-rule") ] []
    , if Array.null detail.notes
        then HH.p [ HP.class_ (H.ClassName "dossier-notes-empty") ]
          [ HH.text "No notes yet." ]
        else HH.ol [ HP.class_ (H.ClassName "dossier-notes-list") ]
          (map renderDossierNote detail.notes)
    , renderDossierNoteComposer state
    ]

-- | Metadata strip at the bottom of the magazine page. All the marginalia
-- | content, condensed into one horizontal row of small-caps labeled blocks.
renderMagazineMetaStrip :: forall m. State -> ProjectDetail -> H.ComponentHTML Action () m
renderMagazineMetaStrip state detail =
  HH.div [ HP.class_ (H.ClassName "magazine-meta-strip") ]
    [ magazineMetaBlock "status" (renderStatusEditor state detail)
    , magazineMetaBlock "domain" (renderDomainEditor state detail)
    , magazineMetaBlock "tags" (renderTagsEditor state detail)
    , magazineMetaBlock "parent" (renderParentBlock state detail)
    , magazineMetaBlock "children" (renderChildrenBlock state detail)
    , magazineMetaBlock "history" (renderHistoryBlock detail)
    , magazineMetaBlock "identifier" (renderIdentifierBlock detail)
    , magazineMetaBlock "external" (renderExternalEditor state detail)
    , magazineMetaBlock "dependencies" (renderDependenciesBlock detail)
    ]

magazineMetaBlock :: forall m. String -> H.ComponentHTML Action () m -> H.ComponentHTML Action () m
magazineMetaBlock label body =
  HH.div [ HP.class_ (H.ClassName "magazine-meta-block") ]
    [ HH.div [ HP.class_ (H.ClassName "magazine-meta-label") ] [ HH.text label ]
    , HH.div [ HP.class_ (H.ClassName "magazine-meta-body") ] [ body ]
    ]

-- | Draft Dossier — the create flow. A slim dossier shell with just an
-- | autofocused title input in the main column. On submit, the project
-- | is created with defaults (domain=programming, status=idea) and we
-- | transition straight into the full dossier where the user can edit
-- | everything else in place. No separate edit form.
renderCreateDossier :: forall m. State -> H.ComponentHTML Action () m
renderCreateDossier state =
  HH.div [ HP.class_ (H.ClassName "dossier dossier-draft") ]
    [ HH.div [ HP.class_ (H.ClassName "dossier-top") ]
        [ HH.div [ HP.class_ (H.ClassName "dossier-top-nav") ]
            [ HH.button
                [ HP.class_ (H.ClassName "dossier-nav-btn")
                , HE.onClick \_ -> CancelForm
                ]
                [ HH.text "‹ cancel" ]
            , HH.span [ HP.class_ (H.ClassName "dossier-page-num") ]
                [ HH.text "new entry" ]
            ]
        ]
    , HH.div [ HP.class_ (H.ClassName "dossier-page") ]
        [ HH.section [ HP.class_ (H.ClassName "dossier-main") ]
            [ HH.div [ HP.class_ (H.ClassName "dossier-draft-hint") ]
                [ HH.text "New project" ]
            , HH.form
                [ HE.onSubmit \_ -> SubmitCreate ]
                [ HH.input
                    [ HP.class_ (H.ClassName "dossier-title-input dossier-draft-input")
                    , HP.type_ HP.InputText
                    , HP.value state.formName
                    , HP.placeholder "Name your project — press Enter to begin"
                    , HP.autofocus true
                    , HE.onValueInput SetFormName
                    ]
                ]
            , HH.p [ HP.class_ (H.ClassName "dossier-draft-footnote") ]
                [ HH.text "Defaults: domain "
                , HH.em_ [ HH.text "programming" ]
                , HH.text ", status "
                , HH.em_ [ HH.text "idea" ]
                , HH.text ". You can change everything after creation."
                ]
            ]
        ]
    ]

-- =============================================================================
-- Action Handler
-- =============================================================================

handleAction :: forall o m. MonadAff m =>
  Action -> H.HalogenM State Action () o m Unit
handleAction = case _ of
  Initialize -> do
    handleAction LoadStats
    handleAction LoadAllProjects
    handleAction LoadPorts
    handleAction LoadProjects
    -- Subscribe to hash changes for browser back/forward
    { emitter: hashEmitter, listener: hashListener } <- liftEffect HS.create
    _ <- liftEffect $ onHashChange_ (\hash -> HS.notify hashListener (HashChange hash))
    void $ H.subscribe hashEmitter
    -- Subscribe to keyboard events
    { emitter: keyEmitter, listener: keyListener } <- liftEffect HS.create
    _ <- liftEffect $ onKeyDown_ (\ke -> HS.notify keyListener (KeyDown ke))
    void $ H.subscribe keyEmitter
    -- Read initial hash for deep linking
    hash <- liftEffect getHash_
    when (not (String.null hash)) do
      handleAction (HashChange hash)

  LoadProjects -> do
    H.modify_ \s -> s { loading = true, error = Nothing }
    state <- H.get
    let mAncestorId = map _.id state.filterAncestor
    rawProjects <- liftAff $ API.fetchProjects state.filterDomain state.filterStatus state.filterTag mAncestorId
      (if String.null state.searchText then Nothing else Just state.searchText)
    -- Apply client-side depth filter using the allProjects cache
    let projects = case state.filterDepth of
          Nothing -> rawProjects
          Just d -> Array.filter (\p -> projectHeight state.allProjects p.id == d) rawProjects
    H.modify_ \s -> s { projects = projects, loading = false }

  LoadAllProjects -> do
    all <- liftAff $ API.fetchProjects Nothing Nothing Nothing Nothing Nothing
    H.modify_ \s -> s { allProjects = all }

  LoadPorts -> do
    servers <- liftAff API.fetchPorts
    H.modify_ \s -> s { servers = servers }

  LoadStats -> do
    mStats <- liftAff API.fetchStats
    H.modify_ \s -> s { stats = mStats }

  SetSection mSec -> do
    H.modify_ \s -> s { section = mSec }
    case mSec of
      Just "finance" -> handleAction LoadSubscriptions
      _ -> pure unit

  LoadSubscriptions -> do
    mResp <- liftAff API.fetchSubscriptions
    case mResp of
      Nothing -> pure unit
      Just resp ->
        H.modify_ \s -> s
          { subscriptions = resp.subscriptions
          , subscriptionMonthlyBurn = resp.monthlyBurn
          }

  SetFilterDomain val -> do
    let mDomain = if String.null val then Nothing else Just val
    -- Switching to a domain clears the Finance section
    H.modify_ \s -> s { filterDomain = mDomain, section = Nothing }
    handleAction LoadProjects

  SetFilterStatus val -> do
    let mStatus = if String.null val then Nothing else Just val
    H.modify_ \s -> s { filterStatus = mStatus }
    handleAction LoadProjects

  SetFilterTag val -> do
    let mTag = if String.null val then Nothing else Just val
    H.modify_ \s -> s { filterTag = mTag }
    handleAction LoadProjects

  TagClick tagName mouseEvent -> do
    isOpt <- liftEffect $ altKey_ (toEvent mouseEvent)
    when isOpt do
      liftEffect $ stopPropagation_ (toEvent mouseEvent)
      state <- H.get
      let newTag = if state.filterTag == Just tagName then "" else tagName
      handleAction (SetFilterTag newTag)

  SetFilterAncestor mAncestor -> do
    H.modify_ \s -> s { filterAncestor = mAncestor, view = ListView, selectedProject = Nothing }
    liftEffect $ setHash_ ""
    handleAction LoadProjects

  SetFilterDepth mDepth -> do
    H.modify_ \s -> s { filterDepth = mDepth }
    handleAction LoadProjects

  SetSearchText val -> do
    H.modify_ \s -> s { searchText = val }
    -- Only search when 3+ characters or empty (cleared)
    when (String.length val >= 3 || String.null val) do
      handleAction LoadProjects

  ClearStatus ->
    H.modify_ \s -> s { error = Nothing }

  DeleteServerAction serverId -> do
    _ <- liftAff $ API.deleteServer serverId
    handleAction LoadPorts

  -- ---- Dossier inline editing (stubs filled in Phase D) ----
  DossierStartEdit field initial -> do
    H.modify_ \s -> s
      { dossierEditField = Just field
      , dossierEditValue = initial
      , dossierNoteOpen = false
      , dossierTagOpen = false
      , dossierDomainOpen = false
      }

  DossierSetEditValue v ->
    H.modify_ \s -> s { dossierEditValue = v }

  DossierCommitEdit -> do
    state <- H.get
    case Tuple state.dossierEditField state.selectedProject of
      Tuple (Just field) (Just detail) -> do
        let newVal = String.trim state.dossierEditValue
        let input = detailToInputWith field newVal detail
        _ <- liftAff $ API.updateProject detail.id input
        -- Refetch to get authoritative data
        mNew <- liftAff $ API.fetchProject detail.id
        H.modify_ \s -> s
          { selectedProject = mNew
          , dossierEditField = Nothing
          , dossierEditValue = ""
          }
        handleAction LoadAllProjects
        handleAction LoadProjects
      _ -> pure unit

  DossierCancelEdit ->
    H.modify_ \s -> s { dossierEditField = Nothing, dossierEditValue = "" }

  DossierSetView newKind -> do
    state <- H.get
    case state.selectedProject of
      Nothing -> pure unit
      Just detail -> do
        -- Optimistic local update so the switch feels instant
        let updated = detail { preferredView = Just (viewKindToString newKind) }
        H.modify_ \s -> s { selectedProject = Just updated }
        -- Persist via PUT (only the preferredView field is non-empty)
        let input = emptyProjectInput { preferredView = viewKindToString newKind }
        _ <- liftAff $ API.updateProject detail.id input
        pure unit

  DossierOpenDomain ->
    H.modify_ \s -> s
      { dossierDomainOpen = true
      , dossierEditField = Nothing
      , dossierNoteOpen = false
      , dossierTagOpen = false
      }

  DossierPickDomain newDomain -> do
    state <- H.get
    case state.selectedProject of
      Nothing -> pure unit
      Just detail -> do
        let input = (detailToInput detail) { domain = newDomain }
        _ <- liftAff $ API.updateProject detail.id input
        mNew <- liftAff $ API.fetchProject detail.id
        H.modify_ \s -> s
          { selectedProject = mNew, dossierDomainOpen = false }
        handleAction LoadAllProjects
        handleAction LoadProjects

  DossierOpenNote -> do
    H.modify_ \s -> s
      { dossierNoteOpen = true
      , dossierNoteDraft = ""
      , dossierEditField = Nothing
      , dossierTagOpen = false
      , dossierDomainOpen = false
      }
    liftEffect focusNoteInput_

  DossierSetNote v ->
    H.modify_ \s -> s { dossierNoteDraft = v }

  DossierSubmitNote -> do
    state <- H.get
    case state.selectedProject of
      Nothing -> pure unit
      Just detail -> do
        let content = String.trim state.dossierNoteDraft
        if String.null content then pure unit
          else do
            liftAff $ API.addNote detail.id content
            mNew <- liftAff $ API.fetchProject detail.id
            H.modify_ \s -> s
              { selectedProject = mNew
              , dossierNoteOpen = false
              , dossierNoteDraft = ""
              }

  DossierCancelNote ->
    H.modify_ \s -> s { dossierNoteOpen = false, dossierNoteDraft = "" }

  DossierOpenTag ->
    H.modify_ \s -> s
      { dossierTagOpen = true
      , dossierTagDraft = ""
      , dossierEditField = Nothing
      , dossierNoteOpen = false
      , dossierDomainOpen = false
      }

  DossierSetTag v ->
    H.modify_ \s -> s { dossierTagDraft = v }

  DossierSubmitTag -> do
    state <- H.get
    case state.selectedProject of
      Nothing -> pure unit
      Just detail -> do
        let tag = String.trim state.dossierTagDraft
        if String.null tag then pure unit
          else do
            _ <- liftAff $ API.addTag detail.id tag
            mNew <- liftAff $ API.fetchProject detail.id
            H.modify_ \s -> s
              { selectedProject = mNew
              , dossierTagOpen = false
              , dossierTagDraft = ""
              }
            handleAction LoadProjects
            handleAction LoadAllProjects

  DossierCancelTag ->
    H.modify_ \s -> s { dossierTagOpen = false, dossierTagDraft = "" }

  SetBlogStatus mStatus ev -> do
    liftEffect $ stopPropagation_ (toEvent ev)
    state <- H.get
    case state.selectedProject of
      Nothing -> pure unit
      Just detail -> case mStatus of
        Nothing -> pure unit  -- UI never sends "clear to unclassified"
        Just bs -> do
          let input = emptyProjectInput { blogStatus = blogStatusToString bs }
          _ <- liftAff $ API.updateProject detail.id input
          mNew <- liftAff $ API.fetchProject detail.id
          H.modify_ \s -> s { selectedProject = mNew }
          handleAction LoadAllProjects
          handleAction LoadProjects

  ClearFilters -> do
    liftEffect $ setHash_ ""
    H.modify_ \s -> s
      { filterDomain = Nothing, filterStatus = Nothing, filterTag = Nothing
      , filterAncestor = Nothing, filterDepth = Nothing, searchText = ""
      , view = ListView, selectedProject = Nothing
      }
    handleAction LoadProjects

  ApplyFilters ->
    handleAction LoadProjects

  SelectProject projectId -> do
    liftEffect $ setHash_ ("project/" <> show projectId)
    H.modify_ \s -> s { view = DetailView projectId, selectedProject = Nothing }
    mDetail <- liftAff $ API.fetchProject projectId
    H.modify_ \s -> s { selectedProject = mDetail }

  CloseDetail -> do
    liftEffect $ setHash_ ""
    H.modify_ \s -> s { view = ListView, selectedProject = Nothing }

  ShowCreateForm -> do
    liftEffect $ setHash_ "new"
    H.modify_ \s -> s
      { view = CreateView
      , formName = ""
      , formDomain = "programming"
      , formSubdomain = ""
      , formStatus = "idea"
      , formDescription = ""
      , formRepo = ""
      , formSourceUrl = ""
      , formSourcePath = ""
      }

  CancelForm -> do
    liftEffect $ setHash_ ""
    H.modify_ \s -> s { view = ListView }

  SubmitCreate -> do
    state <- H.get
    -- Refuse to create with a blank name — avoids accidental empty drafts
    -- when Enter is pressed on an empty input.
    let trimmedName = String.trim state.formName
    when (not (String.null trimmedName)) do
      let input = (buildInput state) { name = trimmedName }
      mProject <- liftAff $ API.createProject input
      case mProject of
        Nothing -> H.modify_ \s -> s { error = Just "Failed to create project" }
        Just p -> do
          handleAction LoadStats
          handleAction LoadAllProjects
          -- Drop straight into the dossier for the newly-created project.
          handleAction (SelectProject p.id)

  SetFormName val ->
    H.modify_ \s -> s { formName = val }

  QuickStatusChange projectId newStatus mouseEvent -> do
    liftEffect $ stopPropagation_ (toEvent mouseEvent)
    let input = emptyProjectInput { status = statusToString newStatus }
    _ <- liftAff $ API.updateProject projectId input
    handleAction LoadProjects
    handleAction LoadAllProjects
    handleAction LoadStats
    -- If this project is currently being viewed in the dossier, refetch
    -- its detail so the visible state matches the server's.
    state <- H.get
    case state.selectedProject of
      Just detail | detail.id == projectId -> do
        mNew <- liftAff $ API.fetchProject projectId
        H.modify_ \s -> s { selectedProject = mNew }
      _ -> pure unit

  NextProject -> cycleSelectedProject 1
  PrevProject -> cycleSelectedProject (-1)

  NavigateToParent -> do
    state <- H.get
    case state.selectedProject of
      Nothing -> pure unit
      Just detail -> case detail.parentId of
        Nothing -> pure unit
        Just pid -> handleAction (SelectProject pid)

  HashChange hash -> do
    state <- H.get
    let currentHash = viewToHash state.view
    -- Only navigate if hash actually changed (avoid loops)
    when (hash /= currentHash) do
      case parseHash hash of
        Just ListView ->
          H.modify_ \s -> s { view = ListView, selectedProject = Nothing }
        Just (DetailView pid) -> do
          H.modify_ \s -> s { view = DetailView pid, selectedProject = Nothing }
          mDetail <- liftAff $ API.fetchProject pid
          H.modify_ \s -> s { selectedProject = mDetail }
        Just CreateView -> handleAction ShowCreateForm
        Nothing -> pure unit

  AutoSave _ -> pure unit

  OpenNotePanel projectId -> do
    H.modify_ \s -> s { notePanel = true, noteProjectId = Just projectId, noteText = "", recording = false }
    liftEffect focusNoteInput_

  CloseNotePanel -> do
    H.modify_ \s -> s { notePanel = false, noteProjectId = Nothing, noteText = "", recording = false }

  SetNoteText val ->
    H.modify_ \s -> s { noteText = val }

  SubmitNote -> do
    state <- H.get
    case state.noteProjectId of
      Nothing -> pure unit
      Just pid -> do
        when (not (String.null state.noteText)) do
          _ <- liftAff $ API.addNote pid state.noteText
          H.modify_ \s -> s { notePanel = false, noteProjectId = Nothing, noteText = "" }
          -- Refresh detail if open
          case state.view of
            DetailView dpid | dpid == pid -> do
              mDetail <- liftAff $ API.fetchProject pid
              H.modify_ \s -> s { selectedProject = mDetail }
            _ -> pure unit

  ToggleRecording -> do
    state <- H.get
    if state.recording
      then do
        -- Stop recording, transcribe, append to note
        H.modify_ \s -> s { recording = false }
        text <- liftAff $ toAffE stopAndTranscribe_
        when (not (String.null text)) do
          H.modify_ \s -> s { noteText = s.noteText <> (if String.null s.noteText then "" else " ") <> text }
      else do
        -- Start recording
        started <- liftAff $ toAffE startRecording_
        when started do
          H.modify_ \s -> s { recording = true }

  OpenAddChild parentId ->
    H.modify_ \s -> s { addChildOpen = Just parentId, addChildName = "" }

  CloseAddChild ->
    H.modify_ \s -> s { addChildOpen = Nothing, addChildName = "" }

  SetAddChildName val ->
    H.modify_ \s -> s { addChildName = val }

  SubmitAddChild parentId -> do
    state <- H.get
    when (not (String.null state.addChildName)) do
      -- Use the parent's domain so the child inherits it
      let parentDomain = case Array.find (\p -> p.id == parentId) state.allProjects of
            Just p -> p.domain
            Nothing -> "programming"
      _ <- liftAff $ API.createChild parentId state.addChildName parentDomain
      -- Clear the input but keep the form open for rapid splitting
      H.modify_ \s -> s { addChildName = "" }
      handleAction LoadAllProjects
      handleAction LoadProjects
      -- Refresh the detail panel so the new child shows in the list
      case state.selectedProject of
        Just detail | detail.id == parentId -> do
          mDetail <- liftAff $ API.fetchProject parentId
          H.modify_ \s -> s { selectedProject = mDetail }
        _ -> pure unit

  StartRename projectId currentName ->
    H.modify_ \s -> s { renameOpen = Just projectId, renameValue = currentName, renameDirectory = false }

  CancelRename ->
    H.modify_ \s -> s { renameOpen = Nothing, renameValue = "", renameDirectory = false }

  SetRenameValue val ->
    H.modify_ \s -> s { renameValue = val }

  ToggleRenameDirectory ->
    H.modify_ \s -> s { renameDirectory = not s.renameDirectory }

  SubmitRename projectId -> do
    state <- H.get
    let trimmed = String.trim state.renameValue
    when (not (String.null trimmed)) do
      resp <- liftAff $ API.renameProject projectId trimmed state.renameDirectory
      if not resp.ok
        then do
          -- Keep the form open so the user can fix and retry
          H.modify_ \s -> s { error = resp.message }
        else do
          H.modify_ \s -> s
            { renameOpen = Nothing
            , renameValue = ""
            , renameDirectory = false
            , error = resp.message  -- carries warnings (may be Nothing)
            }
          -- Refresh everything
          handleAction LoadAllProjects
          handleAction LoadProjects
          case state.selectedProject of
            Just detail | detail.id == projectId -> do
              mDetail <- liftAff $ API.fetchProject projectId
              H.modify_ \s -> s { selectedProject = mDetail }
            _ -> pure unit

  KeyDown ke -> do
    state <- H.get
    -- Don't handle keys when typing in an input field (except Escape and Enter)
    when (not ke.isInput || ke.key == "Escape" || ke.key == "Enter") do
      case state.view of
        ListView -> handleListViewKey ke state
        DetailView _ -> handleDetailViewKey ke
        CreateView -> handleCreateViewKey ke

-- =============================================================================
-- Helpers
-- =============================================================================

buildInput :: State -> ProjectInput
buildInput state =
  { name: state.formName
  , domain: state.formDomain
  , subdomain: state.formSubdomain
  , status: state.formStatus
  , description: state.formDescription
  , repo: state.formRepo
  , sourceUrl: state.formSourceUrl
  , sourcePath: state.formSourcePath
  , statusReason: ""
  , preferredView: ""
  , blogStatus: ""
  , blogContent: ""
  }

-- | A minimal ProjectInput with all fields empty. Used for quick status changes.
emptyProjectInput :: ProjectInput
emptyProjectInput =
  { name: ""
  , domain: ""
  , subdomain: ""
  , status: ""
  , description: ""
  , repo: ""
  , sourceUrl: ""
  , sourcePath: ""
  , statusReason: ""
  , preferredView: ""
  , blogStatus: ""
  , blogContent: ""
  }

-- | Convert a fully-loaded ProjectDetail back into a ProjectInput so it can
-- | be round-tripped through the PUT endpoint. Used by the Dossier view for
-- | single-field edits: copy everything, override one field, submit.
detailToInput :: ProjectDetail -> ProjectInput
detailToInput d =
  { name: d.name
  , domain: d.domain
  , subdomain: fromMaybe "" d.subdomain
  , status: statusToString d.status
  , description: fromMaybe "" d.description
  , repo: fromMaybe "" d.repo
  , sourceUrl: fromMaybe "" d.sourceUrl
  , sourcePath: fromMaybe "" d.sourcePath
  , statusReason: ""
  , preferredView: ""   -- blank means "don't update" (see buildUpdateBody)
  , blogStatus: ""      -- blank means "don't update"
  , blogContent: ""     -- blank means "don't update"
  }

-- | Copy a detail into a ProjectInput with a single field overridden.
-- | Used by the Dossier commit handler.
detailToInputWith :: EditableField -> String -> ProjectDetail -> ProjectInput
detailToInputWith field value d =
  let base = detailToInput d
  in case field of
    FDescription -> base { description = value }
    FSubdomain   -> base { subdomain = value }
    FRepo        -> base { repo = value }
    FSourceUrl   -> base { sourceUrl = value }
    FSourcePath  -> base { sourcePath = value }
    FBlogContent -> base { blogContent = value }

-- | Cycle the currently-selected project in the detail panel by `delta`
-- | (1 for next, -1 for previous), wrapping around the visible project list.
cycleSelectedProject :: forall o m. MonadAff m =>
  Int -> H.HalogenM State Action () o m Unit
cycleSelectedProject delta = do
  state <- H.get
  case state.view of
    DetailView currentId -> do
      let projects = state.projects
      case Array.findIndex (\p -> p.id == currentId) projects of
        Nothing -> pure unit
        Just idx -> do
          let len = Array.length projects
              newIdx = ((idx + delta) `mod` len + len) `mod` len
          case Array.index projects newIdx of
            Nothing -> pure unit
            Just p -> handleAction (SelectProject p.id)
    _ -> pure unit

-- =============================================================================
-- Keyboard Handlers
-- =============================================================================

handleListViewKey :: forall o m. MonadAff m =>
  KeyEvent -> State -> H.HalogenM State Action () o m Unit
handleListViewKey ke state = case ke.key of
  -- Navigation: j/k vertical, h/l horizontal (grid-aware)
  "j" -> moveFocusVertical 1 state
  "ArrowDown" -> moveFocusVertical 1 state
  "k" -> moveFocusVertical (-1) state
  "ArrowUp" -> moveFocusVertical (-1) state
  "l" -> moveFocus 1 state
  "ArrowRight" -> moveFocus 1 state
  "h" -> moveFocus (-1) state
  "ArrowLeft" -> moveFocus (-1) state

  -- Enter: if search is focused, blur to card nav; otherwise open focused card
  "Enter" ->
    if ke.isInput then do
      liftEffect blurActive_
      -- Focus first card if none focused
      when (state.focusIndex < 0) do
        H.modify_ \s -> s { focusIndex = 0 }
    else case focusedProject state of
      Nothing -> pure unit
      Just p -> handleAction (SelectProject p.id)

  -- Open the focused card's dossier (editing happens inline there, no
  -- separate edit mode any more)
  "e" -> case focusedProject state of
    Nothing -> pure unit
    Just p -> handleAction (SelectProject p.id)

  -- Search
  "/" -> do
    liftEffect ke.preventDefault
    liftEffect focusSearch_

  -- Status changes 1-7 on focused card
  "1" -> setFocusedStatus state Idea
  "2" -> setFocusedStatus state Someday
  "3" -> setFocusedStatus state Active
  "4" -> setFocusedStatus state Blocked
  "5" -> setFocusedStatus state Done
  "6" -> setFocusedStatus state Defunct
  "7" -> setFocusedStatus state Evolved

  -- Add note to focused card
  "n" -> do
    liftEffect ke.preventDefault
    case focusedProject state of
      Nothing -> pure unit
      Just p -> handleAction (OpenNotePanel p.id)

  -- Open Claude inbox (project #123) for multi-project dictation
  "i" -> do
    liftEffect ke.preventDefault
    handleAction (OpenNotePanel inboxProjectId)

  -- Escape: close note panel, clear focus, blur search
  "Escape" -> do
    if state.notePanel
      then handleAction CloseNotePanel
      else do
        liftEffect blurActive_
        H.modify_ \s -> s { focusIndex = -1 }

  _ -> pure unit

handleDetailViewKey :: forall o m. MonadAff m =>
  KeyEvent -> H.HalogenM State Action () o m Unit
handleDetailViewKey ke
  -- Cmd-Up: go to parent (Mac Finder convention)
  | ke.key == "ArrowUp" && ke.meta = handleAction NavigateToParent
handleDetailViewKey ke = do
  state <- H.get
  case ke.key of
    "Escape"
      -- Dossier edit state takes priority over closing the detail view.
      | isJust state.dossierEditField -> handleAction DossierCancelEdit
      | state.dossierNoteOpen         -> handleAction DossierCancelNote
      | state.dossierTagOpen          -> handleAction DossierCancelTag
      | state.dossierDomainOpen       -> H.modify_ \s -> s { dossierDomainOpen = false }
      | isJust state.renameOpen       -> handleAction CancelRename
      | otherwise                      -> handleAction CloseDetail
    "Enter"
      -- Commit dossier edits when a text field is being edited (not
      -- FDescription, which is a textarea and needs blur or the add
      -- button). Form-element onSubmit handles most of this, but the
      -- global key handler is the fallback.
      | isJust state.dossierEditField
      , state.dossierEditField /= Just FDescription ->
          handleAction DossierCommitEdit
      | state.dossierTagOpen ->
          handleAction DossierSubmitTag
    _ -> case ke.key of
      "j" -> handleAction NextProject
      "ArrowDown" -> handleAction NextProject
      "k" -> handleAction PrevProject
      -- Plain Up: previous project in view (or parent if visible breadcrumb)
      "ArrowUp" ->
        case state.selectedProject of
          Just detail | isJust detail.parentId
                     , Just _ <- Array.find (\p -> Just p.id == detail.parentId) state.projects ->
            handleAction NavigateToParent
          _ -> handleAction PrevProject
      "n" -> do
        liftEffect ke.preventDefault
        case state.selectedProject of
          Nothing -> pure unit
          Just _  -> handleAction DossierOpenNote
      "i" -> do
        liftEffect ke.preventDefault
        handleAction (OpenNotePanel inboxProjectId)
      _ -> pure unit

-- | Hardcoded project id for the Claude Inbox special project
inboxProjectId :: Int
inboxProjectId = 123

handleCreateViewKey :: forall o m. MonadAff m =>
  KeyEvent -> H.HalogenM State Action () o m Unit
handleCreateViewKey ke = case ke.key of
  "Escape" -> handleAction CancelForm
  _ -> pure unit

moveFocus :: forall o m. MonadAff m =>
  Int -> State -> H.HalogenM State Action () o m Unit
moveFocus delta state = do
  let maxIdx = Array.length state.projects - 1
      newIdx = clamp 0 maxIdx (state.focusIndex + delta)
  H.modify_ \s -> s { focusIndex = newIdx }

moveFocusVertical :: forall o m. MonadAff m =>
  Int -> State -> H.HalogenM State Action () o m Unit
moveFocusVertical direction state = do
  cols <- liftEffect getGridColumns_
  let maxIdx = Array.length state.projects - 1
      delta = direction * cols
      newIdx = clamp 0 maxIdx (state.focusIndex + delta)
  H.modify_ \s -> s { focusIndex = newIdx }

focusedProject :: State -> Maybe Project
focusedProject state =
  if state.focusIndex >= 0
    then Array.index state.projects state.focusIndex
    else Nothing

setFocusedStatus :: forall o m. MonadAff m =>
  State -> Status -> H.HalogenM State Action () o m Unit
setFocusedStatus state newStatus = case focusedProject state of
  Nothing -> pure unit
  Just p -> do
    let input = emptyProjectInput { status = statusToString newStatus }
    _ <- liftAff $ API.updateProject p.id input
    handleAction LoadProjects
    handleAction LoadStats

clamp :: Int -> Int -> Int -> Int
clamp lo hi x
  | x < lo = lo
  | x > hi = hi
  | otherwise = x

-- | Walk the sorted allocated list looking for the first gap starting from `start`.
firstFreePort :: Int -> Array Int -> Int
firstFreePort start xs = case Array.uncons xs of
  Nothing -> start
  Just { head, tail } ->
    if head < start then firstFreePort start tail
    else if head == start then firstFreePort (start + 1) tail
    else start

-- =============================================================================
-- Hash Routing
-- =============================================================================

viewToHash :: View -> String
viewToHash = case _ of
  ListView -> ""
  DetailView pid -> "project/" <> show pid
  CreateView -> "new"

parseHash :: String -> Maybe View
parseHash hash = case hash of
  "" -> Just ListView
  "new" -> Just CreateView
  _ ->
    if String.take 8 hash == "project/" then
      Int.fromString (String.drop 8 hash) <#> DetailView
    -- Legacy edit/:id hash: redirect to the new dossier view
    else if String.take 5 hash == "edit/" then
      Int.fromString (String.drop 5 hash) <#> DetailView
    else
      Nothing

truncate :: Int -> String -> String
truncate maxLen str =
  if String.length str <= maxLen
    then str
    else String.take maxLen str <> "..."
