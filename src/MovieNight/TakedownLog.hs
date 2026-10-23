-- | The append-only takedown log (SPEC §6), the lasting record of
-- takedowns: rows are eventually purged, and the log is what re-applies
-- takedowns after a restore (NFR-13).
module MovieNight.TakedownLog
  ( TakedownEntry (..)
  , appendTakedown
  , readTakedownLog
  ) where

import Data.Aeson (FromJSON (..), ToJSON (..), eitherDecodeStrict, encode, object, withObject, (.:), (.=))
import Data.Aeson.Types (Parser)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Time (UTCTime, defaultTimeLocale, formatTime, parseTimeM)
import MovieNight.PasteId (PasteId, parsePasteId, pasteIdText)
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory)

-- | Never includes the paste's content.
data TakedownEntry = TakedownEntry
  { entryTime :: UTCTime
  , entryPasteId :: PasteId
  , entryReason :: Text
  }
  deriving stock (Eq, Show)

-- | One JSON object per line, e.g.
-- @{"id":"abcdEFGH","reason":"spam","time":"2026-10-23T12:00:00Z"}@.
-- JSON escaping keeps a reason containing newlines on one line.
instance ToJSON TakedownEntry where
  toJSON e =
    object
      [ "time" .= formatTime defaultTimeLocale timeFormat (entryTime e)
      , "id" .= pasteIdText (entryPasteId e)
      , "reason" .= entryReason e
      ]

instance FromJSON TakedownEntry where
  parseJSON = withObject "TakedownEntry" $ \o -> do
    timeText <- o .: "time"
    idText <- o .: "id"
    TakedownEntry
      <$> parseField "time" (parseTimeM False defaultTimeLocale timeFormat timeText)
      <*> parseField "id" (parsePasteId idText)
      <*> o .: "reason"
    where
      parseField :: String -> Maybe a -> Parser a
      parseField name = maybe (fail ("malformed " <> name)) pure

timeFormat :: String
timeFormat = "%Y-%m-%dT%H:%M:%SZ"

-- | Appends one entry, creating the file and its directory if needed.
appendTakedown :: FilePath -> TakedownEntry -> IO ()
appendTakedown path entry = do
  createDirectoryIfMissing True (takeDirectory path)
  BS.appendFile path (BL.toStrict (encode entry) <> "\n")

-- | Reads every entry, oldest first, reporting the first malformed line.
readTakedownLog :: FilePath -> IO (Either String [TakedownEntry])
readTakedownLog path = traverse decodeLine . zip [1 :: Int ..] . filter (not . BS.null) . BC.lines <$> BS.readFile path
  where
    decodeLine (n, line) = either (\e -> Left ("line " <> show n <> ": " <> e)) Right (eitherDecodeStrict line)
