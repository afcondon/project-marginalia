-- | Main application shell component for Project Tracker.
-- |
-- | Single-component architecture: filter bar, stats summary, project list,
-- | detail panel, and create/edit form all managed in one component's state.
module Component.App where

import Prelude

import API as API
import Control.Promise (Promise, toAffE)
import Data.Array as Array
import Data.Int (fromString) as Int
import Data.Maybe (Maybe(..), fromMaybe, isJust)
import Data.String as String
import Effect (Effect)
import Effect.Aff.Class (class MonadAff, liftAff)
import Effect.Class (liftEffect)
import Effect.Console (log)
import Foreign.Object as FO
import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Events as HE
import Halogen.HTML.Properties as HP
import Halogen.Subscription as HS
import Types (Project, ProjectDetail, Stats, ProjectInput, Status(..), allStatuses, statusLabel, statusToString)
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
  | EditView Int

derive instance Eq View

type State =
  { projects :: Array Project
  , selectedProject :: Maybe ProjectDetail
  , stats :: Maybe Stats
  , view :: View
  , filterDomain :: Maybe String
  , filterStatus :: Maybe String
  , filterTag :: Maybe String
  , filterAncestor :: Maybe { id :: Int, name :: String }
  , filterDepth :: Maybe Int  -- 0 = leaves, 1 = parents, 2 = grandparents
  , allProjects :: Array Project  -- unfiltered cache for ancestor/depth lookups
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
  , formStatusReason :: String
  -- Keyboard navigation
  , focusIndex :: Int  -- which card is focused (-1 = none)
  -- Quick note
  , notePanel :: Boolean       -- is note panel open?
  , noteProjectId :: Maybe Int -- which project are we adding a note to?
  , noteText :: String         -- note content being composed
  , recording :: Boolean       -- currently recording audio?
  }

data Action
  = Initialize
  | LoadProjects
  | LoadAllProjects
  | LoadStats
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
  | ShowEditForm
  | CancelForm
  | DiscardEdits Int
  | SubmitCreate
  | SubmitUpdate Int
  | SetFormName String
  | SetFormDomain String
  | SetFormSubdomain String
  | SetFormStatus String
  | SetFormDescription String
  | SetFormRepo String
  | SetFormSourceUrl String
  | SetFormSourcePath String
  | SetFormStatusReason String
  | QuickStatusChange Int Status MouseEvent
  | QuickEdit Int MouseEvent
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
  , filterDomain: Nothing
  , filterStatus: Nothing
  , filterTag: Nothing
  , filterAncestor: Nothing
  , filterDepth: Nothing
  , allProjects: []
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
  , formStatusReason: ""
  , focusIndex: -1
  , notePanel: false
  , noteProjectId: Nothing
  , noteText: ""
  , recording: false
  }

-- =============================================================================
-- Render
-- =============================================================================

render :: forall m. State -> H.ComponentHTML Action () m
render state =
  HH.div [ HP.class_ (H.ClassName "app-shell") ]
    [ renderHeader state
    , HH.main [ HP.class_ (H.ClassName "main-content") ]
        [ case state.view of
            CreateView -> renderForm state Nothing
            EditView _ -> case state.selectedProject of
              Nothing -> renderLoading
              Just detail -> renderForm state (Just detail)
            _ -> renderProjectList state
        ]
    -- Keyboard shortcut hint (shown when no card is focused)
    , if state.view == ListView && state.focusIndex < 0
        then HH.div [ HP.class_ (H.ClassName "keyboard-hint") ]
          [ HH.text "hjkl navigate  /search  enter open  1-7 status  e edit  n note  i inbox  esc close" ]
        else HH.text ""
    -- Slide-out detail panel (overlays the list)
    , case state.view of
        DetailView _ -> case state.selectedProject of
          Nothing -> renderSlidePanel true renderLoading
          Just detail -> renderSlidePanel true (renderDetailPanel state detail)
        _ -> HH.text ""
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
    (renderDomainPills state <> renderDepthPills state)

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
-- Project Card (Task 2: status dot + popover; Task 3: quick edit button)
-- =============================================================================

renderProjectCard :: forall m. State -> Int -> Project -> H.ComponentHTML Action () m
renderProjectCard state idx project =
  let isFocused = state.focusIndex == idx
      focusClass = if isFocused then " card-focused" else ""
  in HH.div
    [ HP.class_ (H.ClassName ("project-card card-domain-" <> project.domain <> focusClass))
    , HE.onClick \_ -> SelectProject project.id
    ]
    [ HH.div [ HP.class_ (H.ClassName "card-header") ]
        [ HH.h3 [ HP.class_ (H.ClassName "card-title") ]
            [ HH.text project.name ]
        , HH.div [ HP.class_ (H.ClassName "card-header-controls") ]
            [ renderStatusControl project
            , renderQuickEditButton project
            ]
        ]
    , HH.div [ HP.class_ (H.ClassName "card-meta") ]
        [ renderDomainLabel project.domain
        , case project.subdomain of
            Nothing -> HH.text ""
            Just sub -> HH.span [ HP.class_ (H.ClassName "card-subdomain") ]
              [ HH.text sub ]
        , case project.slug of
            Nothing -> HH.text ""
            Just s -> HH.span [ HP.class_ (H.ClassName "card-slug") ]
              [ HH.text s ]
        ]
    , case project.description of
        Nothing -> HH.text ""
        Just desc -> HH.p [ HP.class_ (H.ClassName "card-description") ]
          [ HH.text (truncate 120 desc) ]
    , if Array.null project.tags
        then HH.text ""
        else HH.div [ HP.class_ (H.ClassName "card-tags") ]
          (map renderTag project.tags)
    ]

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

-- | Small edit button on the card (Task 3)
renderQuickEditButton :: forall m. Project -> H.ComponentHTML Action () m
renderQuickEditButton project =
  HH.button
    [ HP.class_ (H.ClassName "btn btn-back card-edit-btn")
    , HE.onClick \e -> QuickEdit project.id e
    ]
    [ HH.text "Edit" ]

renderStatusBadge :: forall m. Status -> H.ComponentHTML Action () m
renderStatusBadge status =
  HH.span [ HP.class_ (H.ClassName ("status-badge status-" <> statusToString status)) ]
    [ HH.text (statusLabel status) ]

renderDomainLabel :: forall m. String -> H.ComponentHTML Action () m
renderDomainLabel domain =
  HH.span [ HP.class_ (H.ClassName ("domain-label domain-" <> domain)) ]
    [ HH.text domain ]

renderLoading :: forall m. H.ComponentHTML Action () m
renderLoading =
  HH.div [ HP.class_ (H.ClassName "loading") ]
    [ HH.text "Loading..." ]

-- =============================================================================
-- Detail Panel
-- =============================================================================

renderDetailPanel :: forall m. State -> ProjectDetail -> H.ComponentHTML Action () m
renderDetailPanel state detail =
  HH.div [ HP.class_ (H.ClassName "detail-panel") ]
    [ HH.div [ HP.class_ (H.ClassName "detail-header") ]
        [ HH.div [ HP.class_ (H.ClassName "detail-nav") ]
            [ HH.button
                [ HP.class_ (H.ClassName "btn btn-back")
                , HE.onClick \_ -> PrevProject
                , HP.title "Previous project (k)"
                ]
                [ HH.text "‹" ]
            , HH.button
                [ HP.class_ (H.ClassName "btn btn-back")
                , HE.onClick \_ -> NextProject
                , HP.title "Next project (j)"
                ]
                [ HH.text "›" ]
            ]
        , HH.button
            [ HP.class_ (H.ClassName "btn btn-secondary")
            , HE.onClick \_ -> ShowEditForm
            ]
            [ HH.text "Edit" ]
        , HH.button
            [ HP.class_ (H.ClassName "btn btn-back detail-close")
            , HE.onClick \_ -> CloseDetail
            ]
            [ HH.text "X" ]
        ]
    , HH.div [ HP.class_ (H.ClassName "detail-content") ]
        [ renderParentBreadcrumb state detail
        , HH.h2 [ HP.class_ (H.ClassName "detail-title") ]
            [ HH.text detail.name ]
        , HH.div [ HP.class_ (H.ClassName "detail-meta") ]
            [ renderStatusBadge detail.status
            , renderDomainLabel detail.domain
            , case detail.subdomain of
                Nothing -> HH.text ""
                Just sub -> HH.span [ HP.class_ (H.ClassName "detail-subdomain") ]
                  [ HH.text sub ]
            , case detail.slug of
                Nothing -> HH.text ""
                Just s -> HH.span [ HP.class_ (H.ClassName "detail-slug") ] [ HH.text s ]
            ]
        , case detail.description of
            Nothing -> HH.text ""
            Just desc -> HH.div [ HP.class_ (H.ClassName "detail-description") ]
              [ HH.p_ [ HH.text desc ] ]
        , renderChildrenList state detail
        , renderDetailInfo detail
        , if Array.null detail.tags
            then HH.text ""
            else HH.div [ HP.class_ (H.ClassName "detail-tags") ]
              [ HH.h4_ [ HH.text "Tags" ]
              , HH.div [ HP.class_ (H.ClassName "tag-list") ]
                  (map renderTag detail.tags)
              ]
        , renderDependencies detail
        , renderNotes detail
        ]
    ]

renderDetailInfo :: forall m. ProjectDetail -> H.ComponentHTML Action () m
renderDetailInfo detail =
  let infoRows = Array.catMaybes
        [ detail.repo <#> \r -> { label: "Repository", value: r }
        , detail.sourceUrl <#> \u -> { label: "Source URL", value: u }
        , detail.sourcePath <#> \p -> { label: "Source Path", value: p }
        , detail.createdAt <#> \c -> { label: "Created", value: c }
        , detail.updatedAt <#> \u -> { label: "Updated", value: u }
        ]
  in if Array.null infoRows
    then HH.text ""
    else HH.dl [ HP.class_ (H.ClassName "detail-info") ]
      (Array.concatMap (\row ->
        [ HH.dt_ [ HH.text row.label ]
        , HH.dd_ [ HH.text row.value ]
        ]) infoRows)

-- | Show ancestor chain above the title (P1 = parent, P2 = grandparent, ...)
-- | Each ancestor is a clickable pill that navigates up the chain.
renderParentBreadcrumb :: forall m. State -> ProjectDetail -> H.ComponentHTML Action () m
renderParentBreadcrumb state detail =
  let ancestors = collectAncestors state.allProjects detail.parentId
  in if Array.null ancestors
    then HH.text ""
    else HH.div [ HP.class_ (H.ClassName "detail-breadcrumb") ]
      (Array.mapWithIndex renderAncestor ancestors)
  where
  renderAncestor :: Int -> Project -> H.ComponentHTML Action () m
  renderAncestor i p =
    HH.span
      [ HP.class_ (H.ClassName "breadcrumb-pill")
      , HE.onClick \_ -> SetFilterAncestor (Just { id: p.id, name: p.name })
      , HP.title ("Filter to all descendants of " <> p.name)
      ]
      [ HH.span [ HP.class_ (H.ClassName "breadcrumb-rank") ] [ HH.text ("P" <> show (i + 1)) ]
      , HH.span [ HP.class_ (H.ClassName "breadcrumb-name") ] [ HH.text p.name ]
      ]

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
renderChildrenList :: forall m. State -> ProjectDetail -> H.ComponentHTML Action () m
renderChildrenList state detail =
  let children = Array.filter (\p -> p.parentId == Just detail.id) state.allProjects
  in if Array.null children
    then HH.text ""
    else HH.div [ HP.class_ (H.ClassName "detail-children") ]
      [ HH.h4_ [ HH.text (show (Array.length children) <> " projects in this group") ]
      , HH.div [ HP.class_ (H.ClassName "children-list") ]
          (map renderChildItem children)
      ]

renderChildItem :: forall m. Project -> H.ComponentHTML Action () m
renderChildItem child =
  HH.div
    [ HP.class_ (H.ClassName "child-item")
    , HE.onClick \_ -> SelectProject child.id
    ]
    [ HH.span [ HP.class_ (H.ClassName ("child-status status-light status-light-" <> statusToString child.status <> " current")) ] []
    , HH.span [ HP.class_ (H.ClassName "child-name") ] [ HH.text child.name ]
    , HH.span [ HP.class_ (H.ClassName "child-status-label") ] [ HH.text (statusLabel child.status) ]
    ]

renderDependencies :: forall m. ProjectDetail -> H.ComponentHTML Action () m
renderDependencies detail =
  let hasBlocking = not (Array.null detail.dependencies.blocking)
      hasBlockedBy = not (Array.null detail.dependencies.blockedBy)
  in if not hasBlocking && not hasBlockedBy
    then HH.text ""
    else HH.div [ HP.class_ (H.ClassName "detail-dependencies") ]
      [ HH.h4_ [ HH.text "Dependencies" ]
      , if hasBlockedBy
          then HH.div_
            [ HH.h5_ [ HH.text "Blocked by" ]
            , HH.ul [ HP.class_ (H.ClassName "dep-list") ]
                (map (\d -> HH.li_
                  [ HH.span
                      [ HP.class_ (H.ClassName "dep-link")
                      , HE.onClick \_ -> SelectProject d.projectId
                      ]
                      [ HH.text d.projectName ]
                  , HH.span [ HP.class_ (H.ClassName "dep-type") ]
                      [ HH.text (" (" <> d.dependencyType <> ")") ]
                  ]) detail.dependencies.blockedBy)
            ]
          else HH.text ""
      , if hasBlocking
          then HH.div_
            [ HH.h5_ [ HH.text "Blocks" ]
            , HH.ul [ HP.class_ (H.ClassName "dep-list") ]
                (map (\d -> HH.li_
                  [ HH.span
                      [ HP.class_ (H.ClassName "dep-link")
                      , HE.onClick \_ -> SelectProject d.projectId
                      ]
                      [ HH.text d.projectName ]
                  , HH.span [ HP.class_ (H.ClassName "dep-type") ]
                      [ HH.text (" (" <> d.dependencyType <> ")") ]
                  ]) detail.dependencies.blocking)
            ]
          else HH.text ""
      ]

renderNotes :: forall m. ProjectDetail -> H.ComponentHTML Action () m
renderNotes detail =
  HH.div [ HP.class_ (H.ClassName "detail-notes") ]
    [ HH.h4_ [ HH.text "Notes" ]
    , if Array.null detail.notes
        then HH.p [ HP.class_ (H.ClassName "text-muted") ]
          [ HH.text "No notes yet." ]
        else HH.div [ HP.class_ (H.ClassName "notes-list") ]
          (map renderNote detail.notes)
    ]

renderNote :: forall m. { id :: Int, content :: String, author :: Maybe String, createdAt :: Maybe String } -> H.ComponentHTML Action () m
renderNote note =
  HH.div [ HP.class_ (H.ClassName "note-card") ]
    [ HH.div [ HP.class_ (H.ClassName "note-meta") ]
        [ case note.author of
            Nothing -> HH.text ""
            Just a -> HH.span [ HP.class_ (H.ClassName "note-author") ] [ HH.text a ]
        , case note.createdAt of
            Nothing -> HH.text ""
            Just d -> HH.span [ HP.class_ (H.ClassName "note-date") ] [ HH.text d ]
        ]
    , HH.p [ HP.class_ (H.ClassName "note-content") ]
        [ HH.text note.content ]
    ]

-- =============================================================================
-- Create/Edit Form
-- =============================================================================

renderForm :: forall m. State -> Maybe ProjectDetail -> H.ComponentHTML Action () m
renderForm state mDetail =
  let isEdit = isJust mDetail
      title = if isEdit then "Edit Project" else "New Project"
      submitAction = case mDetail of
        Nothing -> SubmitCreate
        Just d -> SubmitUpdate d.id
  in HH.div [ HP.class_ (H.ClassName "form-panel") ]
    [ HH.div [ HP.class_ (H.ClassName "form-header") ]
        [ HH.h2_ [ HH.text title ]
        , HH.button
            [ HP.class_ (H.ClassName "btn btn-back")
            , HE.onClick \_ -> CancelForm
            ]
            [ HH.text "Cancel" ]
        ]
    , HH.form
        [ HP.class_ (H.ClassName "project-form")
        , HE.onSubmit \_ -> submitAction
        ]
        [ HH.div [ HP.class_ (H.ClassName "form-row") ]
            [ HH.label [ HP.for "name" ] [ HH.text "Name" ]
            , HH.input
                [ HP.type_ HP.InputText
                , HP.id "name"
                , HP.value state.formName
                , HP.placeholder "Project name"
                , HP.required true
                , HE.onValueInput SetFormName
                ]
            ]
        , HH.div [ HP.class_ (H.ClassName "form-row form-row-pair") ]
            [ HH.div [ HP.class_ (H.ClassName "form-field") ]
                [ HH.label [ HP.for "domain" ] [ HH.text "Domain" ]
                , HH.select
                    [ HP.id "domain"
                    , HE.onValueChange SetFormDomain
                    ]
                    (domainFormOptions state)
                ]
            , HH.div [ HP.class_ (H.ClassName "form-field") ]
                [ HH.label [ HP.for "subdomain" ] [ HH.text "Subdomain" ]
                , HH.input
                    [ HP.type_ HP.InputText
                    , HP.id "subdomain"
                    , HP.value state.formSubdomain
                    , HP.placeholder "e.g. hylograph, eurorack"
                    , HE.onValueInput SetFormSubdomain
                    ]
                ]
            ]
        , HH.div [ HP.class_ (H.ClassName "form-row") ]
            [ HH.label [ HP.for "status" ] [ HH.text "Status" ]
            , HH.select
                [ HP.id "status"
                , HE.onValueChange SetFormStatus
                ]
                (map (\s ->
                  HH.option
                    [ HP.value (statusToString s)
                    , HP.selected (statusToString s == state.formStatus)
                    ]
                    [ HH.text (statusLabel s) ]
                ) allStatuses)
            ]
        , if isEdit
            then HH.div [ HP.class_ (H.ClassName "form-row") ]
              [ HH.label [ HP.for "statusReason" ] [ HH.text "Status Change Reason" ]
              , HH.input
                  [ HP.type_ HP.InputText
                  , HP.id "statusReason"
                  , HP.value state.formStatusReason
                  , HP.placeholder "Why is the status changing?"
                  , HE.onValueInput SetFormStatusReason
                  ]
              ]
            else HH.text ""
        , HH.div [ HP.class_ (H.ClassName "form-row") ]
            [ HH.label [ HP.for "description" ] [ HH.text "Description" ]
            , HH.textarea
                [ HP.id "description"
                , HP.value state.formDescription
                , HP.placeholder "What is this project?"
                , HP.rows 4
                , HE.onValueInput SetFormDescription
                ]
            ]
        , HH.div [ HP.class_ (H.ClassName "form-row") ]
            [ HH.label [ HP.for "repo" ] [ HH.text "Repository" ]
            , HH.input
                [ HP.type_ HP.InputText
                , HP.id "repo"
                , HP.value state.formRepo
                , HP.placeholder "e.g. purescript-hylograph-libs"
                , HE.onValueInput SetFormRepo
                ]
            ]
        , HH.div [ HP.class_ (H.ClassName "form-row form-row-pair") ]
            [ HH.div [ HP.class_ (H.ClassName "form-field") ]
                [ HH.label [ HP.for "sourceUrl" ] [ HH.text "Source URL" ]
                , HH.input
                    [ HP.type_ HP.InputText
                    , HP.id "sourceUrl"
                    , HP.value state.formSourceUrl
                    , HP.placeholder "https://..."
                    , HE.onValueInput SetFormSourceUrl
                    ]
                ]
            , HH.div [ HP.class_ (H.ClassName "form-field") ]
                [ HH.label [ HP.for "sourcePath" ] [ HH.text "Source Path" ]
                , HH.input
                    [ HP.type_ HP.InputText
                    , HP.id "sourcePath"
                    , HP.value state.formSourcePath
                    , HP.placeholder "/path/to/project"
                    , HE.onValueInput SetFormSourcePath
                    ]
                ]
            ]
        , HH.div [ HP.class_ (H.ClassName "form-actions") ]
            [ HH.button
                [ HP.class_ (H.ClassName "btn btn-primary")
                , HP.type_ HP.ButtonButton
                , HE.onClick \_ -> submitAction
                ]
                [ HH.text (if isEdit then "Save" else "Create Project") ]
            , HH.button
                [ HP.class_ (H.ClassName "btn btn-secondary")
                , HP.type_ HP.ButtonButton
                , HE.onClick \_ -> CancelForm
                ]
                [ HH.text "Cancel" ]
            ]
        ]
    , case mDetail of
        Just detail ->
          if not (Array.null detail.notes)
            then renderNotes detail
            else HH.text ""
        Nothing -> HH.text ""
    ]

domainFormOptions :: forall m. State -> Array (H.ComponentHTML Action () m)
domainFormOptions state =
  let domains = case state.stats of
        Nothing -> [ "programming", "music", "house", "woodworking", "garden", "infrastructure" ]
        Just stats -> stats.domains
  in map (\d ->
    HH.option
      [ HP.value d
      , HP.selected (d == state.formDomain)
      ]
      [ HH.text d ]
    ) domains

-- =============================================================================
-- Action Handler
-- =============================================================================

handleAction :: forall o m. MonadAff m =>
  Action -> H.HalogenM State Action () o m Unit
handleAction = case _ of
  Initialize -> do
    handleAction LoadStats
    handleAction LoadAllProjects
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

  LoadStats -> do
    mStats <- liftAff API.fetchStats
    H.modify_ \s -> s { stats = mStats }

  SetFilterDomain val -> do
    let mDomain = if String.null val then Nothing else Just val
    H.modify_ \s -> s { filterDomain = mDomain }
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
      , formStatusReason = ""
      }

  ShowEditForm -> do
    state <- H.get
    case state.selectedProject of
      Nothing -> pure unit
      Just detail -> do
        liftEffect $ setHash_ ("edit/" <> show detail.id)
        H.modify_ \s -> s
          { view = EditView detail.id
        , formName = detail.name
        , formDomain = detail.domain
        , formSubdomain = fromMaybe "" detail.subdomain
        , formStatus = statusToString detail.status
        , formDescription = fromMaybe "" detail.description
        , formRepo = fromMaybe "" detail.repo
        , formSourceUrl = fromMaybe "" detail.sourceUrl
        , formSourcePath = fromMaybe "" detail.sourcePath
        , formStatusReason = ""
        }

  CancelForm -> do
    state <- H.get
    case state.view of
      EditView projectId -> do
        liftEffect $ setHash_ ("project/" <> show projectId)
        H.modify_ \s -> s { view = DetailView projectId }
      _ -> do
        liftEffect $ setHash_ ""
        H.modify_ \s -> s { view = ListView }

  DiscardEdits projectId -> do
    liftEffect $ setHash_ ("project/" <> show projectId)
    H.modify_ \s -> s { view = DetailView projectId, selectedProject = Nothing }
    mDetail <- liftAff $ API.fetchProject projectId
    H.modify_ \s -> s { selectedProject = mDetail }

  SubmitCreate -> do
    state <- H.get
    let input = buildInput state
    mProject <- liftAff $ API.createProject input
    case mProject of
      Nothing -> H.modify_ \s -> s { error = Just "Failed to create project" }
      Just _ -> do
        H.modify_ \s -> s { view = ListView }
        handleAction LoadStats
        handleAction LoadProjects

  SubmitUpdate projectId -> do
    liftEffect $ log $ "SubmitUpdate called for project " <> show projectId
    state <- H.get
    let input = buildInput state
    liftEffect $ log $ "Sending update: " <> show input.name <> " / " <> show input.description
    mProject <- liftAff $ API.updateProject projectId input
    case mProject of
      Nothing -> do
        liftEffect $ log "Update returned Nothing"
        H.modify_ \s -> s { error = Just "Failed to update project" }
      Just _ -> do
        liftEffect $ log "Update succeeded"
        -- Reload the detail
        handleAction (SelectProject projectId)
        handleAction LoadStats

  SetFormName val -> do
    H.modify_ \s -> s { formName = val }
    triggerAutoSave
  SetFormDomain val -> do
    H.modify_ \s -> s { formDomain = val }
    triggerAutoSave
  SetFormSubdomain val -> do
    H.modify_ \s -> s { formSubdomain = val }
    triggerAutoSave
  SetFormStatus val -> do
    H.modify_ \s -> s { formStatus = val }
    triggerAutoSave
  SetFormDescription val -> do
    H.modify_ \s -> s { formDescription = val }
    triggerAutoSave
  SetFormRepo val -> do
    H.modify_ \s -> s { formRepo = val }
    triggerAutoSave
  SetFormSourceUrl val -> do
    H.modify_ \s -> s { formSourceUrl = val }
    triggerAutoSave
  SetFormSourcePath val -> do
    H.modify_ \s -> s { formSourcePath = val }
    triggerAutoSave
  SetFormStatusReason val -> H.modify_ \s -> s { formStatusReason = val }

  QuickStatusChange projectId newStatus mouseEvent -> do
    liftEffect $ stopPropagation_ (toEvent mouseEvent)
    let input = emptyProjectInput { status = statusToString newStatus }
    _ <- liftAff $ API.updateProject projectId input
    handleAction LoadProjects
    handleAction LoadAllProjects
    handleAction LoadStats

  NextProject -> cycleSelectedProject 1
  PrevProject -> cycleSelectedProject (-1)

  NavigateToParent -> do
    state <- H.get
    case state.selectedProject of
      Nothing -> pure unit
      Just detail -> case detail.parentId of
        Nothing -> pure unit
        Just pid -> handleAction (SelectProject pid)

  QuickEdit projectId mouseEvent -> do
    liftEffect $ stopPropagation_ (toEvent mouseEvent)
    liftEffect $ setHash_ ("edit/" <> show projectId)
    H.modify_ \s -> s { view = DetailView projectId, selectedProject = Nothing }
    mDetail <- liftAff $ API.fetchProject projectId
    case mDetail of
      Nothing -> pure unit
      Just detail -> H.modify_ \s -> s
        { view = EditView detail.id
        , selectedProject = Just detail
        , formName = detail.name
        , formDomain = detail.domain
        , formSubdomain = fromMaybe "" detail.subdomain
        , formStatus = statusToString detail.status
        , formDescription = fromMaybe "" detail.description
        , formRepo = fromMaybe "" detail.repo
        , formSourceUrl = fromMaybe "" detail.sourceUrl
        , formSourcePath = fromMaybe "" detail.sourcePath
        , formStatusReason = ""
        }

  HashChange hash -> do
    state <- H.get
    let currentHash = viewToHash state.view
    -- Only navigate if hash actually changed (avoid loops)
    when (hash /= currentHash) do
      case parseHash hash of
        Just ListView -> do
          H.modify_ \s -> s { view = ListView, selectedProject = Nothing }
        Just (DetailView pid) -> do
          H.modify_ \s -> s { view = DetailView pid, selectedProject = Nothing }
          mDetail <- liftAff $ API.fetchProject pid
          H.modify_ \s -> s { selectedProject = mDetail }
        Just (EditView pid) -> do
          H.modify_ \s -> s { view = DetailView pid, selectedProject = Nothing }
          mDetail <- liftAff $ API.fetchProject pid
          case mDetail of
            Nothing -> pure unit
            Just detail -> H.modify_ \s -> s
              { view = EditView detail.id
              , selectedProject = Just detail
              , formName = detail.name
              , formDomain = detail.domain
              , formSubdomain = fromMaybe "" detail.subdomain
              , formStatus = statusToString detail.status
              , formDescription = fromMaybe "" detail.description
              , formRepo = fromMaybe "" detail.repo
              , formSourceUrl = fromMaybe "" detail.sourceUrl
              , formSourcePath = fromMaybe "" detail.sourcePath
              , formStatusReason = ""
              }
        Just CreateView -> handleAction ShowCreateForm
        Nothing -> pure unit

  AutoSave projectId -> do
    state <- H.get
    let input = buildInput state
    _ <- liftAff $ API.updateProject projectId input
    pure unit

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

  KeyDown ke -> do
    state <- H.get
    -- Don't handle keys when typing in an input field (except Escape and Enter)
    when (not ke.isInput || ke.key == "Escape" || ke.key == "Enter") do
      case state.view of
        ListView -> handleListViewKey ke state
        DetailView _ -> handleDetailViewKey ke
        EditView _ -> handleEditViewKey ke
        CreateView -> handleEditViewKey ke

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
  , statusReason: state.formStatusReason
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
  }

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

-- | Auto-save: if in edit mode, fire a save
triggerAutoSave :: forall o m. MonadAff m => H.HalogenM State Action () o m Unit
triggerAutoSave = do
  state <- H.get
  case state.view of
    EditView projectId -> handleAction (AutoSave projectId)
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

  -- Edit focused card
  "e" -> case focusedProject state of
    Nothing -> pure unit
    Just p -> do
      liftEffect $ setHash_ ("edit/" <> show p.id)
      H.modify_ \s -> s { view = DetailView p.id, selectedProject = Nothing }
      mDetail <- liftAff $ API.fetchProject p.id
      case mDetail of
        Nothing -> pure unit
        Just detail -> H.modify_ \s -> s
          { view = EditView detail.id
          , selectedProject = Just detail
          , formName = detail.name
          , formDomain = detail.domain
          , formSubdomain = fromMaybe "" detail.subdomain
          , formStatus = statusToString detail.status
          , formDescription = fromMaybe "" detail.description
          , formRepo = fromMaybe "" detail.repo
          , formSourceUrl = fromMaybe "" detail.sourceUrl
          , formSourcePath = fromMaybe "" detail.sourcePath
          , formStatusReason = ""
          }

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
handleDetailViewKey ke = case ke.key of
  "Escape" -> handleAction CloseDetail
  "e" -> handleAction ShowEditForm
  "j" -> handleAction NextProject
  "ArrowDown" -> handleAction NextProject
  "k" -> handleAction PrevProject
  -- Plain Up: previous project in view (or parent if visible breadcrumb)
  "ArrowUp" -> do
    state <- H.get
    case state.selectedProject of
      Just detail | isJust detail.parentId
                 , Just _ <- Array.find (\p -> Just p.id == detail.parentId) state.projects ->
        handleAction NavigateToParent
      _ -> handleAction PrevProject
  "n" -> do
    liftEffect ke.preventDefault
    state <- H.get
    case state.selectedProject of
      Nothing -> pure unit
      Just detail -> handleAction (OpenNotePanel detail.id)
  "i" -> do
    liftEffect ke.preventDefault
    handleAction (OpenNotePanel inboxProjectId)
  _ -> pure unit

-- | Hardcoded project id for the Claude Inbox special project
inboxProjectId :: Int
inboxProjectId = 123

handleEditViewKey :: forall o m. MonadAff m =>
  KeyEvent -> H.HalogenM State Action () o m Unit
handleEditViewKey ke = case ke.key of
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

-- =============================================================================
-- Hash Routing
-- =============================================================================

viewToHash :: View -> String
viewToHash = case _ of
  ListView -> ""
  DetailView pid -> "project/" <> show pid
  CreateView -> "new"
  EditView pid -> "edit/" <> show pid

parseHash :: String -> Maybe View
parseHash hash = case hash of
  "" -> Just ListView
  "new" -> Just CreateView
  _ ->
    if String.take 8 hash == "project/" then
      Int.fromString (String.drop 8 hash) <#> DetailView
    else if String.take 5 hash == "edit/" then
      Int.fromString (String.drop 5 hash) <#> EditView
    else
      Nothing

truncate :: Int -> String -> String
truncate maxLen str =
  if String.length str <= maxLen
    then str
    else String.take maxLen str <> "..."
