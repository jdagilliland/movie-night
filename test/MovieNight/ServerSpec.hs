module MovieNight.ServerSpec (spec) where

import Control.Monad (forM_, replicateM_)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as B64
import Data.ByteString.Lazy qualified as BL
import Data.Map.Strict qualified as Map
import Data.Maybe (fromJust, fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime, addUTCTime, nominalDay)
import MovieNight.Paste
import MovieNight.PasteId (generatePasteId, pasteIdText)
import MovieNight.RateLimit (newRateLimiter)
import MovieNight.Server
import MovieNight.Store
import MovieNight.Store.Memory (newMemoryStore)
import MovieNight.StoreContract (mkPaste, t0)
import MovieNight.Users (hashPasswordWith, parseUsername)
import MovieNight.UsersSpec (cheapParams)
import Network.HTTP.Types (Header, hContentType, hLocation, statusCode)
import Network.Wai (Application)
import Network.Wai.Test (SResponse (..))
import Test.Hspec
import Test.Hspec.Wai
import Web.FormUrlEncoded (urlEncodeAsForm)

live, scripted, leadingNewline, title, takenDown :: Paste
live = mkPaste "abcdEFGH" "hello\nworld"
scripted = mkPaste "scr1pted" "<script>alert(1)</script> & more"
-- Two lines, so it is shown as monospace text, not a marquee.
leadingNewline = mkPaste "newline1" "\nstarts with a newline\nand continues"
title = mkPaste "title001" "  The Grand Budapest Hotel \n"
takenDown = mkPaste "removed1" "gone"

-- | Small, so size limits are easy to test.
maxPasteBytes :: Int
maxPasteBytes = 64

-- | Pastes per user per minute.
rateLimit :: Int
rateLimit = 3

-- | An app over a memory store holding the fixture pastes, at the given time,
-- with one user: alice, password "pw".
mkApp :: UTCTime -> (Store -> Store) -> IO Application
mkApp now modifyStore = do
  store <- newMemoryStore forM_ [live, scripted, leadingNewline, title,
  takenDown] (storeInsert store)
  _ <- storeTakedown store (pasteId takenDown) "spam" t0
  aliceHash <- hashPasswordWith cheapParams "pw"
  rateLimiter <- newRateLimiter rateLimit 60
  pure $
    app
      Env
        { envStore = modifyStore store
        , envBaseUrl = "https://movie.example"
        , envNow = pure now
        , envGenerateId = generatePasteId
        , envUsers = Map.singleton (fromJust (parseUsername "alice")) aliceHash
        , envPasteTtl = 30 * nominalDay
        , envMaxPasteBytes = maxPasteBytes
        , envRateLimiter = rateLimiter
        }

basicAuth :: ByteString -> ByteString -> Header
basicAuth name password = ("Authorization", "Basic " <> B64.encode (name <> ":" <> password))

alice :: Header
alice = basicAuth "alice" "pw"

-- | Submits the new-paste form.
postPaste :: [Header] -> Text -> WaiSession st SResponse
postPaste headers content =
  request "POST" "/" ((hContentType, "application/x-www-form-urlencoded") : headers) $
    urlEncodeAsForm [("content" :: Text, content)]

location :: SResponse -> ByteString
location = fromMaybe "" . lookup hLocation . simpleHeaders

-- | One hour after the fixtures were created; nothing has expired.
beforeExpiry :: UTCTime
beforeExpiry = addUTCTime 3600 t0

path :: Paste -> ByteString
path = TE.encodeUtf8 . ("/" <>) . pasteIdText . pasteId

status :: SResponse -> Int
status = statusCode . simpleStatus

contentType :: SResponse -> Maybe ByteString
contentType = lookup hContentType . simpleHeaders

body :: SResponse -> ByteString
body = BL.toStrict . simpleBody

-- | UTF-8 bytes of a literal. A ByteString literal can't hold "·".
utf8 :: Text -> ByteString
utf8 = TE.encodeUtf8

contains :: ByteString -> ByteString -> Bool
contains haystack needle = needle `BS.isInfixOf` haystack

shouldContainBytes :: ByteString -> ByteString -> Expectation
shouldContainBytes haystack needle =
  haystack `shouldSatisfy` (`contains` needle)

spec :: Spec
spec = do
  with (mkApp beforeExpiry id) $ do
    describe "FR-12, FR-13: GET /:id" $ do
      it "serves the paste as HTML without credentials" $ do
        r <- get (path live)
        liftIO $ do
          status r `shouldBe` 200
          contentType r `shouldBe` Just "text/html;charset=utf-8"
          body r `shouldContainBytes` "<pre>\nhello\nworld</pre>"

      it "NFR-1: escapes content so it is never interpreted as markup" $ do
        r <- get (path scripted)
        liftIO $ do
          body r `shouldContainBytes` "&lt;script&gt;alert(1)&lt;/script&gt; &amp; more"
          body r `shouldNotSatisfy` (`contains` "<script>alert")

      it "preserves a leading newline" $ do
        r <- get (path leadingNewline)
        liftIO $ body r `shouldContainBytes` "<pre>\n\nstarts with a newline\nand continues</pre>"

    describe "§8: a short single-line paste is a marquee" $ do
      it "shows it as the page's only heading, trimmed, and not as monospace text" $ do
        r <- get (path title)
        let count needle = length (filter (BS.isPrefixOf needle) (BS.tails (body r)))
        liftIO $ do
          body r `shouldContainBytes` "<main class=\"marquee\"><h1 class=\"big\">The Grand Budapest Hotel</h1></main>"
          count "<h1" `shouldBe` 1
          body r `shouldNotSatisfy` (`contains` "<pre>")

      -- Previews read the <head> (title, og: and description tags); the tab
      -- title is set by paste.js, which previews don't run.
      it "keeps the title out of everything a link preview reads" $ do
        r <- get (path title)
        let headSection = fst (BS.breakSubstring "<body>" (body r))
        liftIO $ do
          headSection `shouldContainBytes` "<title>Movie Night</title>"
          headSection `shouldContainBytes` "<meta property=\"og:title\" content=\"Movie Night\">"
          headSection `shouldContainBytes` "<meta property=\"og:description\""
          headSection `shouldNotSatisfy` (`contains` "Budapest")

      it "keeps the content exact in the raw view" $ do
        r <- get (path title <> "/raw")
        liftIO $ body r `shouldBe` TE.encodeUtf8 (pasteContent title)

      it "NFR-1: still escapes markup" $ do
        r <- get (path scripted)
        liftIO $ body r `shouldContainBytes` "<h1 class=\"medium\">&lt;script&gt;"

      it "shows multi-line content as monospace text, without a heading" $ do
        r <- get (path live)
        liftIO $ do
          body r `shouldNotSatisfy` (`contains` "<h1")
          body r `shouldContainBytes` utf8 "<title>Movie Night · Paste abcdEFGH</title>"

    describe "FR-15, FR-18: view page contents" $ do
      it "links to the full short URL, with a copy control and its script" $ do
        r <- get (path live)
        liftIO $ do
          body r `shouldContainBytes` "href=\"https://movie.example/abcdEFGH\""
          body r `shouldContainBytes` "id=\"copy-link\""
          body r `shouldContainBytes` "src=\"/static/paste.js\""

      it "shows creation and expiry times in UTC" $ do
        r <- get (path live)
        liftIO $ do
          body r `shouldContainBytes` "Created 2026-10-21 00:00:00 UTC."
          body r `shouldContainBytes` "This paste expires on 2026-11-20 00:00:00 UTC."

      it "puts the link above the content and the timestamps below it" $ do
        r <- get (path live)
        let offset needle = BS.length (fst (BS.breakSubstring needle (body r)))
        liftIO $ do
          offset "id=\"paste-url\"" `shouldSatisfy` (< offset "<pre>")
          offset "<pre>" `shouldSatisfy` (< offset "Created ")
          offset "<header class=\"chrome\">" `shouldSatisfy` (< offset "<pre>")
          offset "<footer class=\"chrome\">" `shouldSatisfy` (> offset "</pre>")

      it "links to the raw view and to a new paste" $ do
        r <- get (path live)
        liftIO $ do
          body r `shouldContainBytes` "href=\"/abcdEFGH/raw\""
          body r `shouldContainBytes` "href=\"/\""

    describe "FR-14: GET /:id/raw" $ do
      it "returns the content exactly, as UTF-8 plain text" $ do
        r <- get (path leadingNewline <> "/raw")
        liftIO $ do
          status r `shouldBe` 200
          contentType r `shouldBe` Just "text/plain;charset=utf-8"
          body r `shouldBe` TE.encodeUtf8 (pasteContent leadingNewline)

      it "returns markup unescaped, since it is not HTML" $ do
        r <- get (path scripted <> "/raw")
        liftIO $ body r `shouldBe` TE.encodeUtf8 (pasteContent scripted)

    describe "FR-16, FR-17: missing pastes" $ do
      it "returns 404 with a not-found page for an unknown ID" $ do
        r <- get "/zzzzzzzz"
        liftIO $ do
          status r `shouldBe` 404
          body r `shouldContainBytes` "Paste not found."
          body r `shouldContainBytes` utf8 "<title>Movie Night · Not found</title>"

      it "returns the identical response for a taken-down paste" $ do
        unknown <- get "/zzzzzzzz"
        removed <- get (path takenDown)
        liftIO $ do
          status removed `shouldBe` 404
          simpleHeaders removed `shouldBe` simpleHeaders unknown
          simpleBody removed `shouldBe` simpleBody unknown

      it "returns 404 on the raw route for unknown and taken-down pastes" $ do
        get "/zzzzzzzz/raw" `shouldRespondWith` 404
        get (path takenDown <> "/raw") `shouldRespondWith` 404

      it "returns the not-found page for any unmatched path" $ do
        r <- get "/abcdEFGH/raw/extra"
        liftIO $ do
          status r `shouldBe` 404
          body r `shouldContainBytes` "Paste not found."

    describe "§10: malformed IDs" $
      it "return 400 on both view routes" $ do
        get "/short" `shouldRespondWith` 400
        get "/short/raw" `shouldRespondWith` 400
        get "/has-dash" `shouldRespondWith` 400

    describe "§8: GET /static/paste.js" $
      it "serves the page script as JavaScript, with copy and tab-title behaviour" $ do
        r <- get "/static/paste.js"
        liftIO $ do
          status r `shouldBe` 200
          contentType r `shouldBe` Just "text/javascript;charset=utf-8"
          body r `shouldContainBytes` "navigator.clipboard"
          body r `shouldContainBytes` utf8 "document.title = \"Movie Night · \""

    describe "NFR-2: security headers" $
      forM_ ["/abcdEFGH", "/abcdEFGH/raw", "/zzzzzzzz", "/short", "/static/paste.js", "/healthz"] $ \p ->
        it ("are set on " <> show p) $ do
          r <- get p
          liftIO $ do
            lookup "Content-Security-Policy" (simpleHeaders r)
              `shouldBe` Just "default-src 'none'; style-src 'self' 'unsafe-inline'; script-src 'self'"
            lookup "X-Content-Type-Options" (simpleHeaders r) `shouldBe` Just "nosniff"
            lookup "Referrer-Policy" (simpleHeaders r) `shouldBe` Just "same-origin"

    describe "NFR-12: GET /healthz" $
      it "returns 200 when the store is healthy" $
        get "/healthz" `shouldRespondWith` "ok\n" {matchStatus = 200}

  with (mkApp beforeExpiry (\s -> s {storeHealthy = pure False})) $
    describe "NFR-12: GET /healthz" $
      it "returns 503 when the store is unhealthy" $
        get "/healthz" `shouldRespondWith` 503

  with (mkApp (addUTCTime (30 * nominalDay) t0) id) $
    describe "FR-16, FR-20: expired pastes" $
      it "return 404 from the expiry instant on" $ do
        get (path live) `shouldRespondWith` 404
        get (path live <> "/raw") `shouldRespondWith` 404

  with (mkApp beforeExpiry id) $ do
    describe "AUTH-4, FR-1: authentication" $ do
      it "challenges an anonymous visitor to / with a sign-in prompt" $ do
        r <- get "/"
        liftIO $ do
          status r `shouldBe` 401
          lookup "WWW-Authenticate" (simpleHeaders r)
            `shouldBe` Just "Basic realm=\"Movie Night\", charset=\"UTF-8\""
          body r `shouldContainBytes` "Sign in to create a paste."

      it "rejects a wrong password, an unknown user, and malformed credentials" $
        forM_
          [ basicAuth "alice" "wrong"
          , basicAuth "mallory" "pw"
          , ("Authorization", "Basic !!!not base64!!!")
          , ("Authorization", "Basic " <> B64.encode "no-colon")
          , ("Authorization", "Bearer " <> B64.encode "alice:pw")
          ]
          $ \h -> request "GET" "/" [h] "" `shouldRespondWith` 401

      it "shows the form to a signed-in user" $ do
        r <- request "GET" "/" [alice] ""
        liftIO $ do
          status r `shouldBe` 200
          body r `shouldContainBytes` "<form method=\"post\" action=\"/\">"
          body r `shouldContainBytes` "<textarea name=\"content\""
          body r `shouldContainBytes` "Signed in as alice."

      it "accepts a lowercase auth scheme" $
        request "GET" "/" [("Authorization", "basic " <> B64.encode "alice:pw")] ""
          `shouldRespondWith` 200

      it "requires credentials to create a paste" $
        postPaste [] "hello" `shouldRespondWith` 401

    describe "FR-2, FR-3: POST /" $ do
      it "creates the paste and redirects to its view page" $ do
        r <- postPaste [alice] "hello"
        liftIO $ do
          status r `shouldBe` 303
          location r `shouldSatisfy` \l -> BS.length l == 9 && "/" `BS.isPrefixOf` l
        get (location r) `shouldRespondWith` 200
        raw <- get (location r <> "/raw")
        liftIO $ body raw `shouldBe` "hello"

      it "FR-6: stores the text with normalized line endings" $ do
        r <- postPaste [alice] "a\r\nb"
        raw <- get (location r <> "/raw")
        liftIO $ body raw `shouldBe` "a\nb"

      it "FR-4: rejects an empty paste, showing the form again" $ do
        r <- postPaste [alice] "  \r\n "
        liftIO $ do
          status r `shouldBe` 400
          body r `shouldContainBytes` "The paste is empty."
          body r `shouldContainBytes` "<textarea"

      it "rejects a form without a content field" $
        request "POST" "/" [alice, (hContentType, "application/x-www-form-urlencoded")] "other=x"
          `shouldRespondWith` 400

    describe "FR-5, NFR-4: size limits" $ do
      it "accepts text of exactly the limit" $
        postPaste [alice] (T.replicate maxPasteBytes "a") `shouldRespondWith` 303

      it "accepts text of the limit even when URL-encoding triples it" $
        -- Each "&" is sent as "%26".
        postPaste [alice] (T.replicate maxPasteBytes "&") `shouldRespondWith` 303

      it "rejects text one byte over the limit with 413, showing the form again" $ do
        r <- postPaste [alice] (T.replicate (maxPasteBytes + 1) "a")
        liftIO $ do
          status r `shouldBe` 413
          body r `shouldContainBytes` "<textarea"

      it "rejects a request body over 3 × the limit + 4 KiB" $
        request "POST" "/" [alice, (hContentType, "application/x-www-form-urlencoded")]
          (BL.fromStrict ("content=" <> BS.replicate (3 * maxPasteBytes + 4096) 0x61))
          `shouldRespondWith` 413

    describe "cross-origin protection" $ do
      it "accepts a post from the app's own origin" $
        postPaste [alice, ("Origin", "https://movie.example")] "hello" `shouldRespondWith` 303

      it "rejects a post from another origin" $
        postPaste [alice, ("Origin", "https://evil.example")] "hello" `shouldRespondWith` 403

      -- Any page can make the browser send "null" by choosing a no-referrer
      -- policy, so accepting it would disable the check.
      it "rejects a post with an opaque (null) origin" $
        postPaste [alice, ("Origin", "null")] "hello" `shouldRespondWith` 403

    describe "NFR-5: rate limiting" $
      it "refuses a user's pastes beyond the limit with 429" $ do
        replicateM_ rateLimit (postPaste [alice] "hello" `shouldRespondWith` 303)
        r <- postPaste [alice] "hello"
        liftIO $ do
          status r `shouldBe` 429
          body r `shouldContainBytes` "Too many new pastes."
