{-# LANGUAGE LambdaCase #-}

-- | Server-rendered pages (SPEC §8). Lucid escapes all text, so user content
-- is never interpreted as markup (NFR-1).
module MovieNight.Html
  ( formPage
  , signInPage
  , pastePage
  , MarqueeSize (..)
  , marqueeSize
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
  page (Just "New paste") $ do
    form_ [method_ "post", action_ "/"] $ do
      maybe mempty (p_ [role_ "alert"] . toHtml) err
      textarea_ [name_ "content", rows_ "20", required_ "required", autofocus_] ""
      p_ (button_ [type_ "submit"] "Create paste")
    p_ ("Signed in as " <> toHtml (usernameText user) <> ".")

-- | Shown when a visitor cancels the browser's sign-in dialog (SPEC §5.3).
signInPage :: Html ()
signInPage =
  page (Just "Sign in") $ do
    p_ "Sign in to create a paste."
    p_ "Viewing a paste doesn't need an account."

-- | FR-13, FR-15, FR-18: the paste view page. Takes the base URL.
--
-- The content is the page's most prominent feature (SPEC §8), between a
-- slim header (link, copy, raw, new paste) and a slim footer (timestamps),
-- both small, faded, and sans-serif. A short single-line paste, almost
-- always a movie title, is a marquee: a huge centered headline. Anything
-- longer is monospace text.
pastePage :: Text -> Paste -> Html ()
pastePage baseUrl paste =
  -- A marquee's title must not appear in what the server sends, or link
  -- previews would spoil it; paste.js puts it in the tab instead.
  page (maybe (Just ("Paste " <> pid)) (const Nothing) (marqueeSize content)) $ do
    header_ [class_ "chrome"] $ do
      a_ [id_ "paste-url", href_ url] (toHtml url)
      " "
      -- Shown by paste.js once it knows the clipboard is available.
      button_ [type_ "button", id_ "copy-link", hidden_ "hidden"] "Copy link"
      " · "
      a_ [href_ ("/" <> pid <> "/raw")] "raw"
      " · "
      a_ [href_ "/"] "new paste"
    case marqueeSize content of
      -- Shown without surrounding whitespace; the raw view keeps it.
      Just size -> main_ [class_ "marquee"] (h1_ [class_ (sizeClass size)] (toHtml (T.strip content)))
      -- HTML drops a newline directly after <pre>, so one is added to keep any
      -- leading newline in the content.
      Nothing -> main_ (pre_ (toHtml ("\n" <> content)))
    footer_ [class_ "chrome"] $ do
      "Created " <> toHtml (formatTimestamp (pasteCreatedAt paste)) <> ". "
      "This paste expires on " <> toHtml (formatTimestamp (pasteExpiresAt paste)) <> "."
    script_ [src_ "/static/paste.js"] ("" :: Text)
  where
    content = pasteContent paste
    pid = pasteIdText (pasteId paste)
    url = baseUrl <> "/" <> pid
    sizeClass = \case
      Big -> "big"
      Medium -> "medium"

data MarqueeSize = Big | Medium
  deriving stock (Eq, Show)

-- | Whether a paste is shown as a marquee, and how big: a single line of at
-- most 100 characters, ignoring surrounding whitespace. Up to 30 characters
-- is big. Longer or multi-line content is shown as monospace text.
marqueeSize :: Text -> Maybe MarqueeSize
marqueeSize t
  | T.any (== '\n') s || n > 100 = Nothing
  | n <= 30 = Just Big
  | otherwise = Just Medium
  where
    s = T.strip t
    n = T.length s

-- | FR-16, FR-17: one page for unknown, expired, and taken-down pastes.
notFoundPage :: Html ()
notFoundPage =
  page (Just "Not found") $ do
    p_ "Paste not found."
    p_ (a_ [href_ "/"] "New paste")

-- | All timestamps are shown in UTC and labeled as such (FR-15).
formatTimestamp :: UTCTime -> Text
formatTimestamp = T.pack . formatTime defaultTimeLocale "%Y-%m-%d %H:%M:%S UTC"

-- | A page titled "Movie Night · <title>", or just "Movie Night".
page :: Maybe Text -> Html () -> Html ()
page title body =
  doctypehtml_ $ do
    head_ $ do
      meta_ [charset_ "utf-8"]
      meta_ [name_ "viewport", content_ "width=device-width, initial-scale=1"]
      -- The app name comes first: tabs truncate from the right, so a
      -- crowded tab still says it's movie night while the title is hidden.
      title_ (toHtml (maybe "Movie Night" ("Movie Night · " <>) title))
      -- Link previews use these in preference to the page's title and
      -- text, so they never show a paste's content (SPEC §8).
      meta_ [term "property" "og:title", content_ "Movie Night"]
      meta_ [term "property" "og:type", content_ "website"]
      meta_ [term "property" "og:description", content_ previewDescription]
      meta_ [name_ "description", content_ previewDescription]
      style_ stylesheet
    body_ body
  where
    previewDescription = "A pick for movie night. Open the link to see what it is."

-- | Minimal styling: browser default colors (light or dark per
-- @prefers-color-scheme@), monospace text, wrapped long lines. The
-- @.chrome@ around a paste is faded with opacity rather than a color, so it
-- follows the light or dark theme; its rules use the faded text color too.
stylesheet :: Text
stylesheet =
  T.unlines
    [ ":root { color-scheme: light dark; }"
    , "body { font-family: ui-monospace, Menlo, Consolas, monospace;"
    , "       max-width: 50rem; margin: 2rem auto; padding: 0 1rem; line-height: 1.4; }"
    , "pre { margin: 0; font-size: 1rem; line-height: 1.5;"
    , "      white-space: pre-wrap; overflow-wrap: anywhere; }"
    , ".chrome { font-family: system-ui, sans-serif; font-size: 0.8rem; opacity: 0.65;"
    , "          overflow-wrap: anywhere; }"
    , ".chrome button { font: inherit; }"
    , "header.chrome { border-bottom: 1px solid; padding-bottom: 0.5rem; margin-bottom: 1.5rem; }"
    , "footer.chrome { border-top: 1px solid; padding-top: 0.5rem; margin-top: 1.5rem; }"
      -- The marquee fills most of the screen; svh ignores phones' toolbars.
    , ".marquee { min-height: 60vh; min-height: 60svh; display: grid;"
    , "           place-items: center; text-align: center; }"
    , ".marquee h1 { margin: 0; max-width: 100%; padding-block: 0.3em;"
    , "              font-family: system-ui, sans-serif; font-weight: 800;"
    , "              letter-spacing: -0.01em; line-height: 1.05; text-wrap: balance;"
    , "              white-space: pre-wrap; overflow-wrap: anywhere;"
    , "              border-block: max(3px, 0.06em) double; }"
    , ".marquee h1.big { font-size: clamp(2.75rem, 11vw, 7rem); }"
    , ".marquee h1.medium { font-size: clamp(1.75rem, 6.5vw, 4rem); }"
    , "textarea { width: 100%; box-sizing: border-box; font: inherit; }"
    ]
