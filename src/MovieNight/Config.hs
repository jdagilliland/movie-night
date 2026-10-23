-- | Configuration from environment variables (SPEC §7.4).
module MovieNight.Config
  ( Config (..)
  , parseConfig
  , loadConfig
  ) where

import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import System.Environment (getEnvironment)
import Text.Read (readMaybe)

data Config = Config
  { cfgPort :: Int
  , cfgDbPath :: FilePath
  , cfgBaseUrl :: Text
  -- ^ Without a trailing slash.
  , cfgMaxPasteBytes :: Int
  , cfgPasteTtlDays :: Int
  , cfgUsersFile :: FilePath
  , cfgTakedownLog :: FilePath
  }
  deriving stock (Eq, Show)

-- | Builds a 'Config' from a variable lookup, applying defaults for unset
-- variables.
parseConfig :: (String -> Maybe String) -> Either String Config
parseConfig lookupVar = do
  port <- intVar "PORT" 8080 1 65535
  maxPasteBytes <- intVar "MAX_PASTE_BYTES" 524288 1 maxBound
  ttlDays <- intVar "PASTE_TTL_DAYS" 30 1 maxBound
  pure
    Config
      { cfgPort = port
      , cfgDbPath = withDefault "DB_PATH" "./data/pastes.db"
      , -- The default follows PORT, so a local server on another port still
        -- passes its own cross-origin check (AUTH-5).
        cfgBaseUrl = T.dropWhileEnd (== '/') (T.pack (withDefault "BASE_URL" ("http://localhost:" <> show port)))
      , cfgMaxPasteBytes = maxPasteBytes
      , cfgPasteTtlDays = ttlDays
      , cfgUsersFile = withDefault "USERS_FILE" "./data/users"
      , cfgTakedownLog = withDefault "TAKEDOWN_LOG" "./data/takedowns.log"
      }
  where
    withDefault name def = fromMaybe def (lookupVar name)

    intVar :: String -> Int -> Int -> Int -> Either String Int
    intVar name def lo hi = case lookupVar name of
      Nothing -> Right def
      Just s -> case readMaybe s of
        Just n | n >= lo && n <= hi -> Right n
        _ -> Left (name <> " must be a number from " <> show lo <> " to " <> show hi <> ", got: " <> show s)

loadConfig :: IO (Either String Config)
loadConfig = do
  env <- getEnvironment
  pure (parseConfig (`lookup` env))
