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

type ClipboardImageData = { filename :: String, base64 :: String }
foreign import onPaste_ :: (ClipboardImageData -> Effect Unit) -> Effect (Effect Unit)

-- =============================================================================
-- Types
-- =============================================================================

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
  -- Create form
  , showCreateForm :: Boolean
  , formTitle :: String
  , formCategory :: String
  , formSlug :: String
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
  | OpenCreateForm
  | CloseCreateForm
  | SetFormTitle String
  | SetFormCategory String
  | SetFormSlug String
  | SubmitCreate
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
  , showCreateForm: false
  , formTitle: ""
  , formCategory: "freestanding"
  , formSlug: ""
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
            , HH.button
                [ HP.class_ (H.ClassName "btn-create")
                , HE.onClick \_ -> OpenCreateForm
                ]
                [ HH.text "+ New Post" ]
            ]
        , HH.div [ HP.class_ (H.ClassName "filter-row") ]
            (renderCategoryPills state)
        ]
    ]

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
renderContent state =
  if state.showCreateForm
    then renderCreateForm state
    else renderPostTable state

renderPostTable :: forall m. State -> H.ComponentHTML Action () m
renderPostTable state =
  let grouped = groupByStatus state.posts
  in HH.div [ HP.class_ (H.ClassName "post-section") ]
    [ HH.div [ HP.class_ (H.ClassName "post-header") ]
        [ HH.span [ HP.class_ (H.ClassName "post-title") ]
            [ HH.text "The Letters Page" ]
        , HH.span [ HP.class_ (H.ClassName "post-count") ]
            [ HH.text (show (Array.length state.posts) <> " entries") ]
        ]
    , if Array.null state.posts
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
renderExpandedPanel state _post =
  HH.tr [ HP.class_ (H.ClassName "expand-row") ]
    [ HH.td [ HP.colSpan 5 ]
        [ HH.div [ HP.class_ (H.ClassName "expand-panel") ]
            [ HH.div [ HP.class_ (H.ClassName "paste-zone") ]
                [ HH.text
                    (if state.uploading
                      then "Uploading\x2026"
                      else "Paste screenshot (Cmd+V) to attach")
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
            , HE.onClick \_ -> CloseCreateForm
            ]
            [ HH.text "Cancel" ]
        ]
    ]

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

  OpenCreateForm ->
    H.modify_ \s -> s { showCreateForm = true, formTitle = "", formCategory = "freestanding", formSlug = "" }

  CloseCreateForm ->
    H.modify_ \s -> s { showCreateForm = false }

  SetFormTitle v -> H.modify_ \s -> s { formTitle = v }
  SetFormCategory v -> H.modify_ \s -> s { formCategory = v }
  SetFormSlug v -> H.modify_ \s -> s { formSlug = v }

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
    H.modify_ \s -> s { showCreateForm = false }
    handleAction LoadPosts
    handleAction LoadCategories

  ClearError ->
    H.modify_ \s -> s { error = Nothing }

-- | Simple slugification: lowercase, replace spaces with hyphens, strip non-alphanumeric.
-- | Uses the FFI for the character-level filtering.
foreign import slugify_ :: String -> String

slugify :: String -> String
slugify = slugify_
