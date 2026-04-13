-- | Klapaucius blog workbench — main application component
module Component.App where

import Prelude

import API as API
import API (PostRecord, AssetRecord) as API
import Data.Array as Array
import Data.Either (Either(..))
import Data.Maybe (Maybe(..), fromMaybe)
import Data.String as String
import Effect (Effect)
import Effect.Aff.Class (class MonadAff, liftAff)
import Effect.Class (liftEffect)
import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Events as HE
import Halogen.HTML.Properties as HP
import Halogen.Subscription as HS
import Web.Event.Event (Event)

-- =============================================================================
-- FFI
-- =============================================================================

foreign import stopPropagation_ :: Event -> Effect Unit
foreign import copyToClipboard :: String -> Effect Unit
foreign import todayMMDD_ :: Effect String

type ClipboardImageData = { filename :: String, base64 :: String }
foreign import onPaste_ :: (ClipboardImageData -> Effect Unit) -> Effect (Effect Unit)

-- =============================================================================
-- Types
-- =============================================================================

-- | Which view is active
data ViewMode
  = PostTable
  | CreateForm
  | TicketBrowser
  | PhotoBrowser
  | PhotoFromPath
  | MusicFromPath
  | FileBrowser

derive instance Eq ViewMode

type State =
  { posts :: Array API.PostRecord
  , categories :: Array API.CategoryRecord
  , filterCategory :: Maybe String
  , filterStatus :: Maybe String
  , loading :: Boolean
  , error :: Maybe String
  -- Expanded row
  , expandedPost :: Maybe Int
  , expandedAssets :: Array API.AssetRecord
  , uploading :: Boolean
  -- View mode
  , viewMode :: ViewMode
  -- Create form
  , formTitle :: String
  , formCategory :: String
  , formSlug :: String
  -- Source browsers
  , tickets :: Array API.TicketRecord
  , photos :: Array API.PhotoRecord
  , photoDate :: String
  , pathInput :: String   -- for photo-from-path and music-from-path
  -- File browser (for music)
  , browserPath :: String
  , browserEntries :: Array API.DirectoryEntry
  }

data Action
  = Initialize
  | LoadPosts
  | LoadCategories
  | SetFilterCategory (Maybe String)
  | SetFilterStatus (Maybe String)
  | ToggleExpand Int
  | SetPostStatus Int String
  | PasteImage ClipboardImageData
  | CopyMarkdown String
  | OpenInVSCode Int
  | SetView ViewMode
  | SetFormTitle String
  | SetFormCategory String
  | SetFormSlug String
  | SubmitCreate
  -- Source browsers
  | LoadTickets
  | SelectTicket API.TicketRecord
  | SetPhotoDate String
  | LoadPhotos
  | SelectPhoto API.PhotoRecord
  | SetPathInput String
  | SubmitPhotoFromPath
  | SubmitMusicFromPath
  | TodayPhotos
  -- File browser
  | SetBrowserPath String
  | BrowsePath String
  | SelectEntry API.DirectoryEntry
  | ClearError

-- =============================================================================
-- Component
-- =============================================================================

component :: forall q i o m. MonadAff m => H.Component q i o m
component = H.mkComponent
  { initialState: \_ -> initialState
  , render
  , eval: H.mkEval H.defaultEval
      { handleAction = handleAction
      , initialize = Just Initialize
      }
  }

initialState :: State
initialState =
  { posts: []
  , categories: []
  , filterCategory: Nothing
  , filterStatus: Nothing
  , loading: false
  , error: Nothing
  , expandedPost: Nothing
  , expandedAssets: []
  , uploading: false
  , viewMode: PostTable
  , formTitle: ""
  , formCategory: "freestanding"
  , formSlug: ""
  , tickets: []
  , photos: []
  , photoDate: ""
  , pathInput: ""
  , browserPath: "/Volumes/Crucial4TB/Music/"
  , browserEntries: []
  }

-- =============================================================================
-- Render
-- =============================================================================

render :: forall m. State -> H.ComponentHTML Action () m
render state =
  HH.div [ HP.class_ (H.ClassName "app-shell") ]
    [ renderHeader state
    , HH.main [ HP.class_ (H.ClassName "app-main") ]
        [ renderContent state ]
    , case state.error of
        Nothing -> HH.text ""
        Just msg -> HH.div
          [ HP.class_ (H.ClassName "status-toast")
          , HE.onClick \_ -> ClearError
          ]
          [ HH.text msg ]
    ]

renderHeader :: forall m. State -> H.ComponentHTML Action () m
renderHeader state =
  HH.header [ HP.class_ (H.ClassName "app-header") ]
    [ HH.div [ HP.class_ (H.ClassName "header-inner") ]
        [ HH.div [ HP.class_ (H.ClassName "header-top") ]
            [ HH.h1 [ HP.class_ (H.ClassName "app-title") ]
                [ HH.text "Klapaucius" ]
            , HH.span [ HP.class_ (H.ClassName "header-subtitle") ]
                [ HH.text "blog workbench" ]
            , HH.div [ HP.class_ (H.ClassName "header-actions") ]
                [ sourceBtn "Tickets" TicketBrowser
                , sourceBtn "Photos" PhotoBrowser
                , sourceBtn "Photo Path" PhotoFromPath
                , sourceBtn "Music" FileBrowser
                , HH.button
                    [ HP.class_ (H.ClassName "btn-create")
                    , HE.onClick \_ -> SetView CreateForm
                    ]
                    [ HH.text "+ New" ]
                ]
            ]
        , HH.div [ HP.class_ (H.ClassName "filter-row") ]
            (renderCategoryPills state)
        ]
    ]

sourceBtn :: forall m. String -> ViewMode -> H.ComponentHTML Action () m
sourceBtn label mode = HH.button
  [ HP.class_ (H.ClassName "btn-source")
  , HE.onClick \_ -> SetView mode
  ]
  [ HH.text label ]

renderCategoryPills :: forall m. State -> Array (H.ComponentHTML Action () m)
renderCategoryPills state =
  [ allPill ] <> map catPill state.categories
  where
  allPill = HH.button
    [ HP.class_ (H.ClassName ("filter-pill" <> if state.filterCategory == Nothing then " filter-pill-active" else ""))
    , HE.onClick \_ -> SetFilterCategory Nothing
    ]
    [ HH.text "All"
    , HH.span [ HP.class_ (H.ClassName "pill-count") ]
        [ HH.text (" (" <> show (Array.length state.posts) <> ")") ]
    ]
  catPill cat = HH.button
    [ HP.class_ (H.ClassName ("filter-pill" <> if state.filterCategory == Just cat.category then " filter-pill-active" else ""))
    , HE.onClick \_ -> SetFilterCategory (Just cat.category)
    ]
    [ HH.text cat.category
    , HH.span [ HP.class_ (H.ClassName "pill-count") ]
        [ HH.text (" (" <> show cat.count <> ")") ]
    ]

renderContent :: forall m. State -> H.ComponentHTML Action () m
renderContent state = case state.viewMode of
  PostTable     -> renderPostTable state
  CreateForm    -> renderCreateForm state
  TicketBrowser -> renderTicketBrowser state
  PhotoBrowser  -> renderPhotoBrowser state
  PhotoFromPath -> renderPhotoFromPath state
  MusicFromPath -> renderMusicFromPath state
  FileBrowser   -> renderFileBrowser state

renderPostTable :: forall m. State -> H.ComponentHTML Action () m
renderPostTable state =
  let grouped = groupByStatus state.posts
  in HH.div [ HP.class_ (H.ClassName "post-section") ]
    [ if Array.null state.posts
        then HH.div [ HP.class_ (H.ClassName "empty-state") ]
          [ HH.text "No blog posts yet. Click '+ New Post' to get started." ]
        else HH.div_
          [ renderGroup state "Drafted"  "drafted"         grouped.drafted
          , renderGroup state "Priority" "wanted_priority" grouped.priority
          , renderGroup state "Wanted"   "wanted"          grouped.wanted
          , renderGroup state "Published" "published"      grouped.published
          , renderGroup state "Not Needed" "not_needed"    grouped.notNeeded
          ]
    ]

type GroupedPosts =
  { drafted :: Array API.PostRecord
  , priority :: Array API.PostRecord
  , wanted :: Array API.PostRecord
  , published :: Array API.PostRecord
  , notNeeded :: Array API.PostRecord
  }

groupByStatus :: Array API.PostRecord -> GroupedPosts
groupByStatus posts =
  { drafted:  Array.filter (\p -> p.status == "drafted") posts
  , priority: Array.filter (\p -> p.status == "wanted_priority") posts
  , wanted:   Array.filter (\p -> p.status == "wanted") posts
  , published: Array.filter (\p -> p.status == "published") posts
  , notNeeded: Array.filter (\p -> p.status == "not_needed") posts
  }

renderGroup :: forall m. State -> String -> String -> Array API.PostRecord -> H.ComponentHTML Action () m
renderGroup state label statusKey posts =
  if Array.null posts
    then HH.text ""
    else HH.div [ HP.class_ (H.ClassName ("post-group post-group-" <> statusKey)) ]
      [ HH.h3 [ HP.class_ (H.ClassName "post-group-label") ]
          [ HH.text label
          , HH.span [ HP.class_ (H.ClassName "post-group-count") ]
              [ HH.text (" (" <> show (Array.length posts) <> ")") ]
          ]
      , HH.table [ HP.class_ (H.ClassName "post-table") ]
          [ HH.thead_
              [ HH.tr_
                  [ HH.th_ [ HH.text "Title" ]
                  , HH.th_ [ HH.text "Category" ]
                  , HH.th_ [ HH.text "File" ]
                  , HH.th [ HP.class_ (H.ClassName "col-words") ] [ HH.text "Words" ]
                  , HH.th_ [ HH.text "" ]
                  ]
              ]
          , HH.tbody_
              (Array.concatMap (renderRowWithExpand state statusKey) posts)
          ]
      ]

renderRowWithExpand :: forall m. State -> String -> API.PostRecord -> Array (H.ComponentHTML Action () m)
renderRowWithExpand state groupStatus post =
  let isExpanded = state.expandedPost == Just post.id
      expandClass = if isExpanded then " row-expanded" else ""
      filename = post.category <> "/" <> post.slug <> "/index.md"
      dataRow = HH.tr
        [ HP.class_ (H.ClassName ("post-row" <> (if post.hasFile then "" else " row-nofile") <> expandClass))
        , HE.onClick \_ -> ToggleExpand post.id
        ]
        [ HH.td [ HP.class_ (H.ClassName "col-title") ]
            [ HH.text post.title ]
        , HH.td [ HP.class_ (H.ClassName "col-category") ]
            [ HH.text post.category ]
        , HH.td [ HP.class_ (H.ClassName "col-file") ]
            [ HH.text (if post.hasFile then filename else "\x2014") ]
        , HH.td [ HP.class_ (H.ClassName "col-words") ]
            [ HH.text (if post.hasFile then show post.wordCount else "\x2014") ]
        , HH.td [ HP.class_ (H.ClassName "col-actions") ]
            (rowActions groupStatus post)
        ]
  in if isExpanded
    then [ dataRow, renderExpandedPanel state post ]
    else [ dataRow ]

rowActions :: forall m. String -> API.PostRecord -> Array (H.ComponentHTML Action () m)
rowActions groupStatus post = case groupStatus of
  "wanted" ->
    [ arrowBtn "\x2191" "Promote to Priority" (SetPostStatus post.id "wanted_priority") "btn-promote"
    , arrowBtn "\x2193" "Demote to Not Needed" (SetPostStatus post.id "not_needed") "btn-demote"
    ]
  "wanted_priority" ->
    [ arrowBtn "\x2193" "Demote to Wanted" (SetPostStatus post.id "wanted") "btn-demote"
    , arrowBtn "\x00d7" "Not Needed" (SetPostStatus post.id "not_needed") "btn-remove"
    ]
  _ -> []
  where
  arrowBtn label title action cls = HH.button
    [ HP.class_ (H.ClassName ("arrow-btn " <> cls))
    , HE.onClick \_ -> action
    , HP.title title
    ]
    [ HH.text label ]

renderExpandedPanel :: forall m. State -> API.PostRecord -> H.ComponentHTML Action () m
renderExpandedPanel state post =
  HH.tr [ HP.class_ (H.ClassName "expand-row") ]
    [ HH.td [ HP.colSpan 5 ]
        [ HH.div [ HP.class_ (H.ClassName "expand-panel") ]
            [ HH.div [ HP.class_ (H.ClassName "expand-actions") ]
                [ HH.button
                    [ HP.class_ (H.ClassName "btn-expand-action")
                    , HE.onClick \_ -> OpenInVSCode post.id
                    , HP.title "Open index.md in VS Code"
                    ]
                    [ HH.text (if post.hasFile then "Edit in VS Code" else "Start in VS Code") ]
                , HH.span [ HP.class_ (H.ClassName "expand-hint") ]
                    [ HH.text (if state.uploading then "Uploading\x2026" else "Cmd+V to paste image") ]
                ]
            , if Array.null state.expandedAssets
                then HH.text ""
                else HH.div [ HP.class_ (H.ClassName "asset-grid") ]
                  (map renderAsset state.expandedAssets)
            ]
        ]
    ]

renderAsset :: forall m. API.AssetRecord -> H.ComponentHTML Action () m
renderAsset asset =
  HH.button
    [ HP.class_ (H.ClassName "asset-thumb")
    , HE.onClick \_ -> CopyMarkdown asset.markdown
    , HP.title ("Click to copy: " <> asset.markdown)
    , HP.type_ HP.ButtonButton
    ]
    [ HH.img [ HP.src asset.url, HP.alt asset.filename ]
    , HH.span [ HP.class_ (H.ClassName "asset-name") ]
        [ HH.text asset.filename ]
    ]

-- =============================================================================
-- Create Form
-- =============================================================================

renderCreateForm :: forall m. State -> H.ComponentHTML Action () m
renderCreateForm state =
  HH.div [ HP.class_ (H.ClassName "create-form") ]
    [ HH.h2_ [ HH.text "New Blog Post" ]
    , HH.label_ [ HH.text "Title" ]
    , HH.input
        [ HP.value state.formTitle
        , HE.onValueInput SetFormTitle
        , HP.placeholder "Post title"
        , HP.autofocus true
        ]
    , HH.label_ [ HH.text "Category" ]
    , HH.select [ HE.onValueInput SetFormCategory ]
        [ HH.option [ HP.value "freestanding", HP.selected (state.formCategory == "freestanding") ] [ HH.text "freestanding" ]
        , HH.option [ HP.value "projects", HP.selected (state.formCategory == "projects") ] [ HH.text "projects" ]
        , HH.option [ HP.value "music", HP.selected (state.formCategory == "music") ] [ HH.text "music" ]
        , HH.option [ HP.value "photos", HP.selected (state.formCategory == "photos") ] [ HH.text "photos" ]
        , HH.option [ HP.value "concerts", HP.selected (state.formCategory == "concerts") ] [ HH.text "concerts" ]
        , HH.option [ HP.value "books", HP.selected (state.formCategory == "books") ] [ HH.text "books" ]
        , HH.option [ HP.value "podcasts", HP.selected (state.formCategory == "podcasts") ] [ HH.text "podcasts" ]
        , HH.option [ HP.value "cooking", HP.selected (state.formCategory == "cooking") ] [ HH.text "cooking" ]
        ]
    , HH.label_ [ HH.text "Slug" ]
    , HH.input
        [ HP.value state.formSlug
        , HE.onValueInput SetFormSlug
        , HP.placeholder "url-safe-slug"
        ]
    , HH.div [ HP.class_ (H.ClassName "form-actions") ]
        [ HH.button
            [ HP.class_ (H.ClassName "btn-submit")
            , HE.onClick \_ -> SubmitCreate
            ]
            [ HH.text "Create" ]
        , HH.button
            [ HP.class_ (H.ClassName "btn-cancel")
            , HE.onClick \_ -> SetView PostTable
            ]
            [ HH.text "Cancel" ]
        ]
    ]

-- =============================================================================
-- Source Browsers
-- =============================================================================

backBtn :: forall m. H.ComponentHTML Action () m
backBtn = HH.button
  [ HP.class_ (H.ClassName "btn-back")
  , HE.onClick \_ -> SetView PostTable
  ]
  [ HH.text "\x2190 Back" ]

-- | Concert ticket browser — table sorted by artist
renderTicketBrowser :: forall m. State -> H.ComponentHTML Action () m
renderTicketBrowser state =
  HH.div [ HP.class_ (H.ClassName "source-browser") ]
    [ backBtn
    , HH.h2 [ HP.class_ (H.ClassName "browser-title") ] [ HH.text "Concert Tickets" ]
    , if Array.null state.tickets
        then HH.p [ HP.class_ (H.ClassName "empty-state") ] [ HH.text "Loading tickets\x2026" ]
        else HH.table [ HP.class_ (H.ClassName "post-table") ]
          [ HH.thead_
              [ HH.tr_
                  [ HH.th_ [ HH.text "Artist" ]
                  , HH.th_ [ HH.text "Venue" ]
                  , HH.th_ [ HH.text "City" ]
                  , HH.th_ [ HH.text "Date" ]
                  , HH.th_ [ HH.text "" ]
                  ]
              ]
          , HH.tbody_
              (map renderTicketRow state.tickets)
          ]
    ]

renderTicketRow :: forall m. API.TicketRecord -> H.ComponentHTML Action () m
renderTicketRow t =
  HH.tr [ HP.class_ (H.ClassName "post-row") ]
    [ HH.td [ HP.class_ (H.ClassName "col-title") ] [ HH.text t.artist ]
    , HH.td_ [ HH.text t.venue ]
    , HH.td [ HP.class_ (H.ClassName "col-category") ] [ HH.text t.city ]
    , HH.td [ HP.class_ (H.ClassName "col-file") ] [ HH.text t.date ]
    , HH.td [ HP.class_ (H.ClassName "col-actions") ]
        [ HH.button
            [ HP.class_ (H.ClassName "btn-select")
            , HE.onClick \_ -> SelectTicket t
            ]
            [ HH.text "Blog this" ]
        ]
    ]

-- | Photo browser — pick a date, see photos, select one
renderPhotoBrowser :: forall m. State -> H.ComponentHTML Action () m
renderPhotoBrowser state =
  HH.div [ HP.class_ (H.ClassName "source-browser") ]
    [ backBtn
    , HH.h2 [ HP.class_ (H.ClassName "browser-title") ] [ HH.text "Photos by Date" ]
    , HH.div [ HP.class_ (H.ClassName "date-picker-row") ]
        [ HH.input
            [ HP.type_ HP.InputText
            , HP.value state.photoDate
            , HE.onValueInput SetPhotoDate
            , HP.placeholder "MM-DD"
            , HP.class_ (H.ClassName "date-input")
            ]
        , HH.button
            [ HP.class_ (H.ClassName "btn-today")
            , HE.onClick \_ -> TodayPhotos
            ]
            [ HH.text "Today" ]
        , HH.button
            [ HP.class_ (H.ClassName "btn-submit")
            , HE.onClick \_ -> LoadPhotos
            ]
            [ HH.text "Load" ]
        , HH.span [ HP.class_ (H.ClassName "post-count") ]
            [ HH.text (show (Array.length state.photos) <> " photos") ]
        ]
    , if Array.null state.photos
        then HH.text ""
        else HH.div [ HP.class_ (H.ClassName "photo-grid") ]
          (map renderPhotoCard state.photos)
    ]

renderPhotoCard :: forall m. API.PhotoRecord -> H.ComponentHTML Action () m
renderPhotoCard p =
  HH.div
    [ HP.class_ (H.ClassName "photo-card")
    , HE.onClick \_ -> SelectPhoto p
    , HP.title (p.fileName <> " \x2014 " <> p.captureTime)
    ]
    [ HH.img [ HP.src p.thumbUrl, HP.alt p.fileName, HP.class_ (H.ClassName "photo-thumb-img") ]
    , HH.div [ HP.class_ (H.ClassName "photo-meta") ]
        [ HH.span_ [ HH.text p.fileName ]
        , HH.span [ HP.class_ (H.ClassName "photo-time") ]
            [ HH.text (String.take 10 p.captureTime) ]
        ]
    ]

-- | Photo from path — text input for a fully qualified path
renderPhotoFromPath :: forall m. State -> H.ComponentHTML Action () m
renderPhotoFromPath state =
  HH.div [ HP.class_ (H.ClassName "source-browser") ]
    [ backBtn
    , HH.h2 [ HP.class_ (H.ClassName "browser-title") ] [ HH.text "Photo from Path" ]
    , HH.div [ HP.class_ (H.ClassName "path-form") ]
        [ HH.label_ [ HH.text "Photo path" ]
        , HH.input
            [ HP.value state.pathInput
            , HE.onValueInput SetPathInput
            , HP.placeholder "/Volumes/Crucial4TB/Photos/..."
            , HP.autofocus true
            , HP.class_ (H.ClassName "path-input")
            ]
        , HH.label_ [ HH.text "Title" ]
        , HH.input
            [ HP.value state.formTitle
            , HE.onValueInput SetFormTitle
            , HP.placeholder "Post title"
            ]
        , HH.label_ [ HH.text "Slug" ]
        , HH.input
            [ HP.value state.formSlug
            , HE.onValueInput SetFormSlug
            , HP.placeholder "url-safe-slug"
            ]
        , HH.div [ HP.class_ (H.ClassName "form-actions") ]
            [ HH.button
                [ HP.class_ (H.ClassName "btn-submit")
                , HE.onClick \_ -> SubmitPhotoFromPath
                ]
                [ HH.text "Create Post" ]
            ]
        ]
    ]

-- | Music from path — text input for a file or folder path
renderMusicFromPath :: forall m. State -> H.ComponentHTML Action () m
renderMusicFromPath state =
  HH.div [ HP.class_ (H.ClassName "source-browser") ]
    [ backBtn
    , HH.h2 [ HP.class_ (H.ClassName "browser-title") ] [ HH.text "Music from Path" ]
    , HH.div [ HP.class_ (H.ClassName "path-form") ]
        [ HH.label_ [ HH.text "Track or album path" ]
        , HH.input
            [ HP.value state.pathInput
            , HE.onValueInput SetPathInput
            , HP.placeholder "/Volumes/Crucial4TB/Music/Artist/Album/..."
            , HP.autofocus true
            , HP.class_ (H.ClassName "path-input")
            ]
        , HH.label_ [ HH.text "Title" ]
        , HH.input
            [ HP.value state.formTitle
            , HE.onValueInput SetFormTitle
            , HP.placeholder "Post title"
            ]
        , HH.label_ [ HH.text "Slug" ]
        , HH.input
            [ HP.value state.formSlug
            , HE.onValueInput SetFormSlug
            , HP.placeholder "url-safe-slug"
            ]
        , HH.div [ HP.class_ (H.ClassName "form-actions") ]
            [ HH.button
                [ HP.class_ (H.ClassName "btn-submit")
                , HE.onClick \_ -> SubmitMusicFromPath
                ]
                [ HH.text "Create Post" ]
            ]
        ]
    ]

-- | Music file browser — navigate directories, select a file or folder
renderFileBrowser :: forall m. State -> H.ComponentHTML Action () m
renderFileBrowser state =
  HH.div [ HP.class_ (H.ClassName "source-browser") ]
    [ backBtn
    , HH.h2 [ HP.class_ (H.ClassName "browser-title") ] [ HH.text "Music Browser" ]
    , HH.div [ HP.class_ (H.ClassName "browser-breadcrumb") ]
        [ HH.span [ HP.class_ (H.ClassName "breadcrumb-path") ]
            [ HH.text state.browserPath ]
        ]
    , HH.div [ HP.class_ (H.ClassName "browser-path-row") ]
        [ HH.input
            [ HP.value state.browserPath
            , HE.onValueInput SetBrowserPath
            , HP.placeholder "/Volumes/Crucial4TB/Music/"
            , HP.class_ (H.ClassName "path-input")
            ]
        , HH.button
            [ HP.class_ (H.ClassName "btn-submit")
            , HE.onClick \_ -> BrowsePath state.browserPath
            ]
            [ HH.text "Go" ]
        ]
    , if Array.null state.browserEntries
        then HH.p [ HP.class_ (H.ClassName "empty-state") ]
          [ HH.text "Enter a path and click Go to browse." ]
        else HH.div [ HP.class_ (H.ClassName "file-browser-list") ]
          (map (renderBrowserEntry state) state.browserEntries)
    ]

renderBrowserEntry :: forall m. State -> API.DirectoryEntry -> H.ComponentHTML Action () m
renderBrowserEntry _state entry =
  HH.div [ HP.class_ (H.ClassName ("browser-entry" <> if entry.isDirectory then " browser-dir" else " browser-file")) ]
    [ HH.span
        [ HP.class_ (H.ClassName "entry-icon") ]
        [ HH.text (if entry.isDirectory then "\x1f4c1" else "\x1f3b5") ]
    , HH.span
        [ HP.class_ (H.ClassName "entry-name")
        , HE.onClick \_ -> if entry.isDirectory then BrowsePath entry.path else SetPathInput entry.path
        ]
        [ HH.text entry.name ]
    , if entry.isDirectory
        then HH.button
          [ HP.class_ (H.ClassName "btn-select")
          , HE.onClick \_ -> SelectEntry entry
          ]
          [ HH.text "Blog this" ]
        else if isAudioFile entry.name
          then HH.button
            [ HP.class_ (H.ClassName "btn-select")
            , HE.onClick \_ -> SelectEntry entry
            ]
            [ HH.text "Blog this" ]
          else HH.text ""
    ]

isAudioFile :: String -> Boolean
isAudioFile name =
  let lower = String.toLower name
  in String.contains (String.Pattern ".mp3") lower
  || String.contains (String.Pattern ".m4a") lower
  || String.contains (String.Pattern ".flac") lower
  || String.contains (String.Pattern ".wav") lower
  || String.contains (String.Pattern ".aac") lower
  || String.contains (String.Pattern ".ogg") lower
  || String.contains (String.Pattern ".aiff") lower
  || String.contains (String.Pattern ".alac") lower

-- =============================================================================
-- Action Handlers
-- =============================================================================

handleAction :: forall o m. MonadAff m => Action -> H.HalogenM State Action () o m Unit
handleAction = case _ of
  Initialize -> do
    -- Subscribe to paste events
    { emitter: pasteEmitter, listener: pasteListener } <- liftEffect HS.create
    _ <- liftEffect $ onPaste_ (\imgData -> HS.notify pasteListener (PasteImage imgData))
    void $ H.subscribe pasteEmitter
    handleAction LoadCategories
    handleAction LoadPosts

  LoadPosts -> do
    st <- H.get
    mResp <- liftAff $ API.fetchPosts st.filterCategory st.filterStatus
    case mResp of
      Nothing -> pure unit
      Just resp -> H.modify_ \s -> s { posts = resp.posts }

  LoadCategories -> do
    cats <- liftAff $ API.fetchCategories
    H.modify_ \s -> s { categories = cats }

  SetFilterCategory mCat -> do
    H.modify_ \s -> s { filterCategory = mCat }
    handleAction LoadPosts

  SetFilterStatus mStat -> do
    H.modify_ \s -> s { filterStatus = mStat }
    handleAction LoadPosts

  ToggleExpand postId -> do
    st <- H.get
    if st.expandedPost == Just postId
      then H.modify_ \s -> s { expandedPost = Nothing, expandedAssets = [] }
      else do
        assets <- liftAff $ API.fetchAssets postId
        H.modify_ \s -> s { expandedPost = Just postId, expandedAssets = assets }

  SetPostStatus postId newStatus -> do
    let input = { title: "", status: newStatus, category: "", slug: "" }
    _ <- liftAff $ API.updatePost postId input
    handleAction LoadPosts
    handleAction LoadCategories

  PasteImage imgData -> do
    st <- H.get
    case st.expandedPost of
      Nothing -> pure unit
      Just postId -> do
        H.modify_ \s -> s { uploading = true }
        result <- liftAff $ API.uploadAsset postId imgData.filename imgData.base64
        case result of
          Left err ->
            H.modify_ \s -> s { uploading = false, error = Just ("Upload failed: " <> err) }
          Right info -> do
            liftEffect $ copyToClipboard info.markdown
            assets <- liftAff $ API.fetchAssets postId
            H.modify_ \s -> s { uploading = false, expandedAssets = assets }

  CopyMarkdown md ->
    liftEffect $ copyToClipboard md

  OpenInVSCode postId -> do
    _ <- liftAff $ API.openInVSCode postId
    -- Refetch so hasFile updates if a template was created
    handleAction LoadPosts

  SetView mode -> do
    H.modify_ \s -> s
      { viewMode = mode
      , formTitle = ""
      , formCategory = "freestanding"
      , formSlug = ""
      , pathInput = ""
      }
    case mode of
      TicketBrowser -> handleAction LoadTickets
      FileBrowser -> handleAction (BrowsePath "/Volumes/Crucial4TB/Music/")
      _ -> pure unit

  SetFormTitle v -> H.modify_ \s -> s { formTitle = v }
  SetFormCategory v -> H.modify_ \s -> s { formCategory = v }
  SetFormSlug v -> H.modify_ \s -> s { formSlug = v }
  SetPathInput v -> H.modify_ \s -> s { pathInput = v }
  SetPhotoDate v -> H.modify_ \s -> s { photoDate = v }

  SubmitCreate -> do
    st <- H.get
    let slug = if String.null st.formSlug then slugify st.formTitle else st.formSlug
    let input =
          { category: st.formCategory
          , slug: slug
          , title: st.formTitle
          , status: "wanted"
          , sourceType: "freestanding"
          , sourceId: ""
          }
    _ <- liftAff $ API.createPost input
    H.modify_ \s -> s { viewMode = PostTable }
    handleAction LoadPosts
    handleAction LoadCategories

  -- Source browsers
  LoadTickets -> do
    resp <- liftAff API.fetchTickets
    H.modify_ \s -> s { tickets = resp.tickets }

  SelectTicket t -> do
    let slug = slugify (t.artist <> "-" <> t.venue <> "-" <> String.take 4 t.date)
    let cityPart = if t.city == "" then "" else ", " <> t.city
    let datePart = if t.date == "" then "" else " (" <> t.date <> ")"
    let title = t.artist <> " at " <> t.venue <> cityPart <> datePart
    let input =
          { category: "concerts"
          , slug: slug
          , title: title
          , status: "drafted"
          , sourceType: "infovore_concerts"
          , sourceId: t.artist <> "|" <> t.date
          }
    _ <- liftAff $ API.createPost input
    H.modify_ \s -> s { viewMode = PostTable }
    handleAction LoadPosts
    handleAction LoadCategories

  LoadPhotos -> do
    st <- H.get
    resp <- liftAff $ API.fetchPhotosByDate st.photoDate
    H.modify_ \s -> s { photos = resp.photos }

  SelectPhoto p -> do
    let datePart = String.take 10 p.captureTime
    let slug = slugify (p.fileName <> "-" <> datePart)
    let title = p.fileName <> " (" <> datePart <> ")"
    _ <- liftAff $ API.createFromPhoto { path: p.filePath, title, slug }
    H.modify_ \s -> s { viewMode = PostTable }
    handleAction LoadPosts
    handleAction LoadCategories

  SubmitPhotoFromPath -> do
    st <- H.get
    let slug = if String.null st.formSlug then slugify st.formTitle else st.formSlug
    _ <- liftAff $ API.createFromPhoto { path: st.pathInput, title: st.formTitle, slug }
    H.modify_ \s -> s { viewMode = PostTable }
    handleAction LoadPosts
    handleAction LoadCategories

  SubmitMusicFromPath -> do
    st <- H.get
    let slug = if String.null st.formSlug then slugify st.formTitle else st.formSlug
    _ <- liftAff $ API.createFromMusic { path: st.pathInput, title: st.formTitle, slug }
    H.modify_ \s -> s { viewMode = PostTable }
    handleAction LoadPosts
    handleAction LoadCategories

  TodayPhotos -> do
    today <- liftEffect todayMMDD_
    H.modify_ \s -> s { photoDate = today }
    handleAction LoadPhotos

  SetBrowserPath v ->
    H.modify_ \s -> s { browserPath = v }

  BrowsePath dirPath -> do
    H.modify_ \s -> s { browserPath = dirPath, browserEntries = [] }
    resp <- liftAff $ API.fetchDirectory dirPath
    H.modify_ \s -> s { browserEntries = resp.items }

  SelectEntry entry -> do
    let title = entry.name
    let slug = slugify entry.name
    _ <- liftAff $ API.createFromMusic { path: entry.path, title, slug }
    H.modify_ \s -> s { viewMode = PostTable }
    handleAction LoadPosts
    handleAction LoadCategories

  ClearError ->
    H.modify_ \s -> s { error = Nothing }

-- | Simple slugification: lowercase, replace spaces with hyphens, strip non-alphanumeric.
-- | Uses the FFI for the character-level filtering.
foreign import slugify_ :: String -> String

slugify :: String -> String
slugify = slugify_
