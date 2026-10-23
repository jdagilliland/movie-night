-- | Validating and storing new pastes (SPEC §4.1, §4.2).
module MovieNight.Create
  ( CreateError (..)
  , validateContent
  , createPaste
  , maxIdAttempts
  ) where

import Data.ByteString qualified as BS
import Data.Char (isSpace)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (NominalDiffTime, UTCTime, addUTCTime)
import MovieNight.Content (normalizeLineEndings)
import MovieNight.Paste (Paste (..))
import MovieNight.PasteId (PasteId)
import MovieNight.Store

data CreateError
  = EmptyContent
  -- ^ FR-4: empty or whitespace-only.
  | ContentTooLarge
  -- ^ FR-5: over the size limit.
  | NoFreeId
  -- ^ FR-10: every generated ID was already taken.
  deriving stock (Eq, Show)

-- | Normalizes line endings (FR-6) and checks the result against the size
-- limit in UTF-8 bytes (FR-5). The limit applies to the text as stored.
validateContent :: Int -> Text -> Either CreateError Text
validateContent maxBytes raw
  | T.all isSpace normalized = Left EmptyContent
  | BS.length (TE.encodeUtf8 normalized) > maxBytes = Left ContentTooLarge
  | otherwise = Right normalized
  where
    normalized = normalizeLineEndings raw

-- | FR-10: the first attempt plus 7 retries.
maxIdAttempts :: Int
maxIdAttempts = 8

-- | Stores validated content under the first free ID among the candidates,
-- trying at most 'maxIdAttempts' of them. Also takes the paste lifetime, the
-- creator's username, and the current time.
createPaste :: Store -> [PasteId] -> NominalDiffTime -> Text -> UTCTime -> Text -> IO (Either CreateError PasteId)
createPaste store candidates ttl createdBy now content = go (take maxIdAttempts candidates)
  where
    -- Truncated as the store would, so expiry is a whole number of seconds
    -- after creation (FR-19).
    createdAt = truncateToSecond now

    go :: [PasteId] -> IO (Either CreateError PasteId)
    go [] = pure (Left NoFreeId)
    go (pid : rest) = do
      result <-
        storeInsert store
          Paste
            { pasteId = pid
            , pasteContent = content
            , pasteCreatedBy = createdBy
            , pasteCreatedAt = createdAt
            , pasteExpiresAt = addUTCTime ttl createdAt
            }
      case result of
        Right () -> pure (Right pid)
        Left DuplicateId -> go rest
