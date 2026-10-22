{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TemplateHaskell #-}

-- | The HTTP API and its handlers (SPEC §10).
module MovieNight.Server
  ( Env (..)
  , PublicAPI
  , app
  , securityHeaders
  ) where

import Control.Monad.IO.Class (liftIO)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BL
import Data.FileEmbed (embedFile)
import Data.Text (Text)
import Data.Time (UTCTime)
import Lucid (Html, renderBS)
import MovieNight.Html (notFoundPage, pastePage)
import MovieNight.Paste (Paste (..))
import MovieNight.PasteId (PasteId)
import MovieNight.Store
import Network.HTTP.Media ((//), (/:))
import Network.HTTP.Types (hContentType)
import Network.Wai (Middleware)
import Network.Wai.Middleware.AddHeaders (addHeaders)
import Servant
import Servant.HTML.Lucid (HTML)

data Env = Env
  { envStore :: Store
  , envBaseUrl :: Text
  -- ^ Without a trailing slash.
  , envNow :: IO UTCTime
  }

-- | Fixed paths come before the captures (SPEC §10, route ordering).
type PublicAPI =
       "healthz" :> Get '[PlainText] Text
  :<|> "static" :> "copy.js" :> Get '[JavaScript] ByteString
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
  securityHeaders $
    serveWithContext (Proxy @PublicAPI) (errorFormatters :. EmptyContext) (server env)

server :: Env -> Server PublicAPI
server env = healthz :<|> pure copyJs :<|> viewPaste :<|> rawPaste
  where
    healthz = do
      healthy <- liftIO (storeHealthy (envStore env))
      if healthy then pure "ok\n" else throwError err503 {errBody = "unavailable\n"}

    viewPaste pid = pastePage (envBaseUrl env) <$> findPaste notFoundHtml pid

    -- FR-14: the content exactly as stored.
    rawPaste pid = pasteContent <$> findPaste notFoundPlain pid

    -- FR-16, FR-17: unknown, expired, and taken-down pastes all get the same
    -- 404, so viewers can't tell them apart.
    findPaste notFound pid = do
      now <- liftIO (envNow env)
      result <- liftIO (storeLookup (envStore env) now pid)
      case result of
        Found paste -> pure paste
        _ -> throwError notFound

notFoundHtml :: ServerError
notFoundHtml =
  err404
    { errBody = renderBS notFoundPage
    , errHeaders = [(hContentType, "text/html;charset=utf-8")]
    }

notFoundPlain :: ServerError
notFoundPlain =
  err404
    { errBody = "Paste not found\n"
    , errHeaders = [(hContentType, "text/plain;charset=utf-8")]
    }

-- | A malformed paste ID is a 400 (SPEC §10); any unmatched path gets the
-- same 404 page as a missing paste.
errorFormatters :: ErrorFormatters
errorFormatters =
  defaultErrorFormatters
    { urlParseErrorFormatter = \_ _ _ ->
        err400
          { errBody = "Bad request: malformed paste ID\n"
          , errHeaders = [(hContentType, "text/plain;charset=utf-8")]
          }
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
