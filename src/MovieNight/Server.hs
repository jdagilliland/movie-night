{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
-- Servant's generalized auth requires an AuthServerData instance for its own
-- AuthProtect type, which is necessarily an orphan.
{-# OPTIONS_GHC -Wno-orphans #-}

-- | The HTTP API and its handlers (SPEC §10).
module MovieNight.Server
  ( Env (..)
  , API
  , app
  , securityHeaders
  ) where

import Control.Monad (replicateM, unless)
import Control.Monad.IO.Class (liftIO)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as B64
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.FileEmbed (embedFile)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (NominalDiffTime, UTCTime)
import Lucid (Html, renderBS)
import MovieNight.Create
import MovieNight.Html (formPage, notFoundPage, pastePage, signInPage)
import MovieNight.Paste (Paste (..))
import MovieNight.PasteId (PasteId, pasteIdText)
import MovieNight.RateLimit (RateLimiter, allow)
import MovieNight.Store
import MovieNight.Users (User (..), Users, authenticate, usernameText)
import Network.HTTP.Media ((//), (/:))
import Network.HTTP.Types (HeaderName, hAuthorization, hContentType)
import Network.Wai (Middleware, Request, requestHeaders)
import Network.Wai.Middleware.AddHeaders (addHeaders)
import Network.Wai.Middleware.RequestSizeLimit
  ( defaultRequestSizeLimitSettings
  , requestSizeLimitMiddleware
  , setMaxLengthForRequest
  )
import Servant
import Servant.HTML.Lucid (HTML)
import Servant.Server.Experimental.Auth (AuthHandler, AuthServerData, mkAuthHandler)
import Web.FormUrlEncoded (FromForm (..), parseUnique)

data Env = Env
  { envStore :: Store
  , envBaseUrl :: Text
  -- ^ Without a trailing slash.
  , envNow :: IO UTCTime
  , envGenerateId :: IO PasteId
  , envUsers :: Users
  , envPasteTtl :: NominalDiffTime
  , envMaxPasteBytes :: Int
  , envRateLimiter :: RateLimiter
  }

-- | SPEC §5.2: handlers receive the authenticated user from this combinator.
type instance AuthServerData (AuthProtect "session") = User

newtype PasteForm = PasteForm {formContent :: Text}

instance FromForm PasteForm where
  fromForm f = PasteForm <$> parseUnique "content" f

-- | Fixed paths come before the captures (SPEC §10, route ordering).
type API =
       "healthz" :> Get '[PlainText] Text
  :<|> "static" :> "copy.js" :> Get '[JavaScript] ByteString
  :<|> AuthProtect "session" :> Get '[HTML] (Html ())
  :<|> AuthProtect "session"
         :> Header "Origin" Text
         :> ReqBody '[FormUrlEncoded] PasteForm
         :> Verb 'POST 303 '[HTML] (Headers '[Header "Location" Text] NoContent)
  :<|> Capture "pasteId" PasteId :> Get '[HTML] (Html ())
  :<|> Capture "pasteId" PasteId :> "raw" :> Get '[PlainText] Text

data JavaScript

instance Accept JavaScript where
  contentType _ = "text" // "javascript" /: ("charset", "utf-8")

instance MimeRender JavaScript ByteString where
  mimeRender _ = BL.fromStrict

copyJs :: ByteString
copyJs = $(embedFile "static/copy.js")

app :: Env -> Application
app env =
  securityHeaders . bodySizeLimit (envMaxPasteBytes env) $
    serveWithContext
      (Proxy @API)
      (basicAuthHandler (envUsers env) :. errorFormatters :. EmptyContext)
      (server env)

server :: Env -> Server API
server env =
  healthz
    :<|> pure copyJs
    :<|> (\user -> pure (formPage (userName user) Nothing))
    :<|> createHandler
    :<|> viewPaste
    :<|> rawPaste
  where
    healthz = do
      healthy <- liftIO (storeHealthy (envStore env))
      if healthy then pure "ok\n" else throwError err503 {errBody = "unavailable\n"}

    createHandler user origin form = do
      checkOrigin origin
      let name = usernameText (userName user)
          formError = formErrorFor user
      content <- either (throwError . createError formError) pure $
        validateContent (envMaxPasteBytes env) (formContent form)
      now <- liftIO (envNow env)
      allowed <- liftIO (allow (envRateLimiter env) name now)
      unless allowed $
        throwError (formError 429 "Too Many Requests" "Too many new pastes. Try again in a minute.")
      candidates <- liftIO (replicateM maxIdAttempts (envGenerateId env))
      result <- liftIO (createPaste (envStore env) candidates (envPasteTtl env) name now content)
      case result of
        Right pid -> pure (addHeader ("/" <> pasteIdText pid) NoContent)
        Left err -> throwError (createError formError err)

    -- Basic auth credentials are sent with every request, including ones a
    -- different site triggers, so a cross-origin form post is rejected.
    -- Requests without an Origin header (e.g. curl) are allowed.
    checkOrigin = \case
      Just origin | origin /= envBaseUrl env -> throwError (plainError err403 "Forbidden: cross-origin request\n")
      _ -> pure ()

    createError formError = \case
      EmptyContent -> formError 400 "Bad Request" "The paste is empty."
      ContentTooLarge ->
        formError 413 "Payload Too Large" $
          "The paste is larger than the " <> T.pack (show (envMaxPasteBytes env `div` 1024)) <> " KiB limit."
      NoFreeId -> plainError err500 "Could not allocate a paste ID. Please try again.\n"

    formErrorFor user code reason message =
      ServerError
        { errHTTPCode = code
        , errReasonPhrase = reason
        , errBody = renderBS (formPage (userName user) (Just message))
        , errHeaders = [htmlContentType]
        }

    viewPaste pid = pastePage (envBaseUrl env) <$> findPaste notFoundHtml pid

    -- FR-14: the content exactly as stored.
    rawPaste pid = pasteContent <$> findPaste (plainError err404 "Paste not found\n") pid

    -- FR-16, FR-17: unknown, expired, and taken-down pastes all get the same
    -- 404, so viewers can't tell them apart.
    findPaste notFound pid = do
      now <- liftIO (envNow env)
      result <- liftIO (storeLookup (envStore env) now pid)
      case result of
        Found paste -> pure paste
        _ -> throwError notFound

-- | SPEC §5.3: HTTP Basic credentials checked against the users file.
basicAuthHandler :: Users -> AuthHandler Request User
basicAuthHandler users = mkAuthHandler $ \req ->
  case basicCredentials req >>= uncurry (authenticate users) of
    Just user -> pure user
    Nothing -> throwError unauthorized

-- | The username and password from an @Authorization: Basic …@ header.
basicCredentials :: Request -> Maybe (Text, Text)
basicCredentials req = do
  header <- lookup hAuthorization (requestHeaders req)
  let (scheme, rest) = BC.break (== ' ') header
  unless (BC.map toLowerAscii scheme == "basic") Nothing
  decoded <- either (const Nothing) Just (B64.decode (BC.dropWhile (== ' ') rest))
  let (name, password) = BS.break (== 0x3a) decoded -- ':'
  unless (BS.isPrefixOf ":" password) Nothing
  (,) <$> utf8 name <*> utf8 (BS.drop 1 password)
  where
    utf8 = either (const Nothing) Just . TE.decodeUtf8'
    toLowerAscii c = if c >= 'A' && c <= 'Z' then toEnum (fromEnum c + 32) else c

-- | AUTH-4: prompts the browser for credentials.
unauthorized :: ServerError
unauthorized =
  err401
    { errBody = renderBS signInPage
    , errHeaders =
        [ ("WWW-Authenticate", "Basic realm=\"Movie Night\", charset=\"UTF-8\"")
        , htmlContentType
        ]
    }

-- | NFR-4: caps the raw body at 3 × the paste limit (worst-case URL-encoding
-- growth) plus 4 KiB; the decoded text is checked separately (FR-5).
bodySizeLimit :: Int -> Middleware
bodySizeLimit maxPasteBytes =
  requestSizeLimitMiddleware $
    setMaxLengthForRequest
      (\_ -> pure (Just (fromIntegral (3 * maxPasteBytes + 4096))))
      defaultRequestSizeLimitSettings

notFoundHtml :: ServerError
notFoundHtml = err404 {errBody = renderBS notFoundPage, errHeaders = [htmlContentType]}

plainError :: ServerError -> BL.ByteString -> ServerError
plainError err body = err {errBody = body, errHeaders = [(hContentType, "text/plain;charset=utf-8")]}

htmlContentType :: (HeaderName, ByteString)
htmlContentType = (hContentType, "text/html;charset=utf-8")

-- | A malformed paste ID is a 400 (SPEC §10); any unmatched path gets the
-- same 404 page as a missing paste.
errorFormatters :: ErrorFormatters
errorFormatters =
  defaultErrorFormatters
    { urlParseErrorFormatter = \_ _ _ -> plainError err400 "Bad request: malformed paste ID\n"
    , notFoundErrorFormatter = const notFoundHtml
    }

-- | NFR-2: added to every response, including errors.
securityHeaders :: Middleware
securityHeaders = addHeaders headers
  where
    headers :: [(ByteString, ByteString)]
    headers =
      [ ("Content-Security-Policy", "default-src 'none'; style-src 'self' 'unsafe-inline'; script-src 'self'")
      , ("X-Content-Type-Options", "nosniff")
      , ("Referrer-Policy", "no-referrer")
      ]
