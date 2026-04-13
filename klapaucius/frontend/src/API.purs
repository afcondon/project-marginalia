-- | HTTP client for the Klapaucius blog workbench API.
module API
  ( fetchPosts
  , fetchPost
  , createPost
  , updatePost
  , deletePost
  , fetchAssets
  , uploadAsset
  , fetchStats
  , fetchCategories
  , PostListResponse
  , PostRecord
  , AssetRecord
  , CategoryRecord
  , CreatePostInput
  , UpdatePostInput
  ) where

import Prelude

import Data.Array as Array
import Affjax.Web as AX
import Affjax.RequestBody as RequestBody
import Affjax.ResponseFormat as ResponseFormat
import Data.Argonaut.Core (toObject, toString) as J
import Data.Argonaut.Parser (jsonParser)
import Data.Either (Either(..))
import Data.Maybe (Maybe(..), fromMaybe)
import Effect.Aff (Aff)
import Effect.Class (liftEffect)
import Effect.Console (log)
import Foreign.Object (lookup) as FO

foreign import computedBaseUrl :: String
foreign import arrayLength :: forall a. Array a -> Int
foreign import unsafeIndex :: forall a. Array a -> Int -> a
foreign import parsePostListResponse_ :: String -> PostListResponse
foreign import parsePostDetailResponse_ :: String -> PostRecord
foreign import parseAssetsResponse_ :: String -> Array AssetRecord
foreign import parseStatsResponse_ :: String -> StatsResponse
foreign import parseCategoriesResponse_ :: String -> Array CategoryRecord
foreign import buildCreateBody :: CreatePostInput -> String
foreign import buildUpdateBody :: UpdatePostInput -> String
foreign import buildAssetUploadBody :: String -> String -> String

baseUrl :: String
baseUrl = computedBaseUrl

type PostListResponse =
  { posts :: Array PostRecord
  , count :: Int
  }

type PostRecord =
  { id :: Int
  , category :: String
  , slug :: String
  , title :: String
  , status :: String
  , sourceType :: String
  , wordCount :: Int
  , hasFile :: Boolean
  , createdAt :: String
  , updatedAt :: String
  }

type AssetRecord =
  { filename :: String
  , size :: Int
  , url :: String
  , markdown :: String
  }

type StatsResponse =
  { total :: Int
  }

type CategoryRecord =
  { category :: String
  , count :: Int
  }

type CreatePostInput =
  { category :: String
  , slug :: String
  , title :: String
  , status :: String
  , sourceType :: String
  , sourceId :: String
  }

type UpdatePostInput =
  { title :: String
  , status :: String
  , category :: String
  , slug :: String
  }

fetchPosts :: Maybe String -> Maybe String -> Aff (Maybe PostListResponse)
fetchPosts mCategory mStatus = do
  let qs = buildQS mCategory mStatus
  result <- AX.get ResponseFormat.string (baseUrl <> "/api/posts" <> qs)
  case result of
    Left _ -> pure Nothing
    Right response -> pure (Just (parsePostListResponse_ response.body))

fetchPost :: Int -> Aff (Maybe PostRecord)
fetchPost postId = do
  result <- AX.get ResponseFormat.string (baseUrl <> "/api/posts/" <> show postId)
  case result of
    Left _ -> pure Nothing
    Right response -> pure (Just (parsePostDetailResponse_ response.body))

createPost :: CreatePostInput -> Aff (Maybe PostRecord)
createPost input = do
  let body = buildCreateBody input
  result <- AX.post ResponseFormat.string (baseUrl <> "/api/posts") (Just (RequestBody.string body))
  case result of
    Left _ -> pure Nothing
    Right response -> pure (Just (parsePostDetailResponse_ response.body))

updatePost :: Int -> UpdatePostInput -> Aff (Maybe PostRecord)
updatePost postId input = do
  let body = buildUpdateBody input
  result <- AX.put ResponseFormat.string (baseUrl <> "/api/posts/" <> show postId) (Just (RequestBody.string body))
  case result of
    Left _ -> pure Nothing
    Right response -> pure (Just (parsePostDetailResponse_ response.body))

deletePost :: Int -> Aff Boolean
deletePost postId = do
  result <- AX.delete ResponseFormat.string (baseUrl <> "/api/posts/" <> show postId)
  case result of
    Left _ -> pure false
    Right _ -> pure true

fetchAssets :: Int -> Aff (Array AssetRecord)
fetchAssets postId = do
  result <- AX.get ResponseFormat.string (baseUrl <> "/api/posts/" <> show postId <> "/assets")
  case result of
    Left _ -> pure []
    Right response -> pure (parseAssetsResponse_ response.body)

uploadAsset :: Int -> String -> String -> Aff (Either String { filename :: String, markdown :: String })
uploadAsset postId filename base64Data = do
  let url = baseUrl <> "/api/posts/" <> show postId <> "/assets"
  let body = buildAssetUploadBody filename base64Data
  result <- AX.post ResponseFormat.string url (Just (RequestBody.string body))
  case result of
    Left err -> pure (Left (AX.printError err))
    Right response -> case jsonParser response.body of
      Left _ -> pure (Left "failed to parse response")
      Right json -> case J.toObject json of
        Nothing -> pure (Left "response was not an object")
        Just obj -> case FO.lookup "error" obj of
          Just errJson -> pure (Left (fromMaybe "unknown" (J.toString errJson)))
          Nothing -> do
            let fn = fromMaybe "" (J.toString =<< FO.lookup "filename" obj)
            let md = fromMaybe "" (J.toString =<< FO.lookup "markdown" obj)
            pure (Right { filename: fn, markdown: md })

fetchStats :: Aff (Maybe StatsResponse)
fetchStats = do
  result <- AX.get ResponseFormat.string (baseUrl <> "/api/stats")
  case result of
    Left _ -> pure Nothing
    Right response -> pure (Just (parseStatsResponse_ response.body))

fetchCategories :: Aff (Array CategoryRecord)
fetchCategories = do
  result <- AX.get ResponseFormat.string (baseUrl <> "/api/categories")
  case result of
    Left _ -> pure []
    Right response -> pure (parseCategoriesResponse_ response.body)

buildQS :: Maybe String -> Maybe String -> String
buildQS mCat mStat =
  let ps = Array.catMaybes
        [ map (\c -> "category=" <> c) mCat
        , map (\s -> "status=" <> s) mStat
        ]
  in case ps of
    [] -> ""
    _ -> "?" <> Array.intercalate "&" ps
