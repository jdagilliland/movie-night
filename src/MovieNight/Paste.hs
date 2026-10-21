module MovieNight.Paste
  ( Paste (..)
  ) where

import Data.Text (Text)
import Data.Time (UTCTime)
import MovieNight.PasteId (PasteId)

data Paste = Paste
  { pasteId :: PasteId
  , pasteContent :: Text
  , pasteCreatedBy :: Text
  -- ^ AUTH-3: the creating user's username.
  , pasteCreatedAt :: UTCTime
  , pasteExpiresAt :: UTCTime
  -- ^ FR-19: fixed at creation time.
  }
  deriving stock (Eq, Show)
