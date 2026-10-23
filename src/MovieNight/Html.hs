-- | Server-rendered pages (SPEC §8). Lucid escapes all text, so user content
-- is never interpreted as markup (NFR-1).
module MovieNight.Html
  ( formPage
  , signInPage
  , pastePage
  , notFoundPage
  , formatTimestamp
  ) where

import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime, defaultTimeLocale, formatTime)
import Lucid
import MovieNight.Paste (Paste (..))
import MovieNight.PasteId (pasteIdText)
import MovieNight.Users (Username, usernameText)

-- | FR-1: the new-paste form, with an optional error message.
formPage :: Username -> Maybe Text -> Html ()
formPage user err =
  page "New paste" $ do
    form_ [method_ "post", action_ "/"] $ do
      maybe mempty (p_ [role_ "alert"] . toHtml) err
      textarea_ [name_ "content", rows_ "20", required_ "required", autofocus_] ""
      p_ (button_ [type_ "submit"] "Create paste")
    p_ ("Signed in as " <> toHtml (usernameText user) <> ".")

-- | Shown when a visitor cancels the browser's sign-in dialog (SPEC §5.3).
signInPage :: Html ()
signInPage =
  page "Sign in" $ do
    p_ "Sign in to create a paste."
    p_ "Viewing a paste doesn't need an account."

-- | FR-13, FR-15, FR-18: the paste view page. Takes the base URL.
pastePage :: Text -> Paste -> Html ()
pastePage baseUrl paste =
  page ("Paste " <> pid) $ do
    p_ $ do
      a_ [id_ "paste-url", href_ url] (toHtml url)
      " "
      -- Shown by copy.js once it knows the clipboard is available.
      button_ [type_ "button", id_ "copy-link", hidden_ "hidden"] "Copy link"
    p_ $ do
      "Created " <> toHtml (formatTimestamp (pasteCreatedAt paste)) <> ". "
      "This paste expires on " <> toHtml (formatTimestamp (pasteExpiresAt paste)) <> "."
    nav_ $ do
      a_ [href_ ("/" <> pid <> "/raw")] "raw"
      " · "
      a_ [href_ "/"] "new paste"
    -- HTML drops a newline directly after <pre>, so one is added to keep any
    -- leading newline in the content.
    pre_ (toHtml ("\n" <> pasteContent paste))
    script_ [src_ "/static/copy.js"] ("" :: Text)
  where
    pid = pasteIdText (pasteId paste)
    url = baseUrl <> "/" <> pid

-- | FR-16, FR-17: one page for unknown, expired, and taken-down pastes.
notFoundPage :: Html ()
notFoundPage =
  page "Not found" $ do
    p_ "Paste not found."
    p_ (a_ [href_ "/"] "New paste")

-- | All timestamps are shown in UTC and labeled as such (FR-15).
formatTimestamp :: UTCTime -> Text
formatTimestamp = T.pack . formatTime defaultTimeLocale "%Y-%m-%d %H:%M:%S UTC"

page :: Text -> Html () -> Html ()
page title body =
  doctypehtml_ $ do
    head_ $ do
      meta_ [charset_ "utf-8"]
      meta_ [name_ "viewport", content_ "width=device-width, initial-scale=1"]
      title_ (toHtml (title <> " · Movie Night"))
      style_ stylesheet
    body_ body

-- | Minimal styling: browser default colors (light or dark per
-- @prefers-color-scheme@), monospace text, wrapped long lines.
stylesheet :: Text
stylesheet =
  T.unlines
    [ ":root { color-scheme: light dark; }"
    , "body { font-family: ui-monospace, Menlo, Consolas, monospace;"
    , "       max-width: 50rem; margin: 2rem auto; padding: 0 1rem; line-height: 1.4; }"
    , "pre { white-space: pre-wrap; overflow-wrap: anywhere; }"
    , "textarea { width: 100%; box-sizing: border-box; font: inherit; }"
    ]
