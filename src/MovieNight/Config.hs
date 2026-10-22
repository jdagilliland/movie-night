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
  }
  deriving stock (Eq, Show)

-- | Builds a 'Config' from a variable lookup, applying defaults for unset
-- variables.
parseConfig :: (String -> Maybe String) -> Either String Config
parseConfig lookupVar = do
  port <- case lookupVar "PORT" of
    Nothing -> Right 8080
    Just s -> case readMaybe s of
      Just p | p >= 1 && p <= 65535 -> Right p
      _ -> Left ("PORT must be a number from 1 to 65535, got: " <> show s)
  pure
    Config
      { cfgPort = port
      , cfgDbPath = withDefault "DB_PATH" "./data/pastes.db"
      , cfgBaseUrl = T.dropWhileEnd (== '/') (T.pack (withDefault "BASE_URL" "http://localhost:8080"))
      }
  where
    withDefault name def = fromMaybe def (lookupVar name)

loadConfig :: IO (Either String Config)
loadConfig = do
  env <- getEnvironment
  pure (parseConfig (`lookup` env))
