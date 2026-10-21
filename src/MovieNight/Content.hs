-- | Transformations applied to pasted text before storage (SPEC §4.1).
module MovieNight.Content
  ( normalizeLineEndings
  ) where

import Data.Text (Text)
import Data.Text qualified as T

-- | FR-6: normalizes CRLF and lone CR line endings to LF.
--
-- Browsers submit textarea contents with CRLF line endings, and HTML treats
-- a lone CR as a line break too, so both become @\\n@.
normalizeLineEndings :: Text -> Text
normalizeLineEndings = T.replace "\r" "\n" . T.replace "\r\n" "\n"
