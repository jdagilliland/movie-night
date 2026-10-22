module MovieNight.Store.SQLiteSpec (spec) where

import Data.Text (Text)
import Database.SQLite.Simple (Only (..), query_, withConnection)
import MovieNight.Paste
import MovieNight.Store
import MovieNight.Store.SQLite (withSQLiteStore)
import MovieNight.StoreContract (mkPaste, storeContract, t0)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

-- | Runs an action with the path of a database file in a fresh temporary
-- directory. The file itself doesn't exist yet.
withDbPath :: (FilePath -> IO a) -> IO a
withDbPath action =
  withSystemTempDirectory "movie-night" $ \dir -> action (dir </> "db" </> "pastes.db")

spec :: Spec
spec = do
  storeContract (\action -> withDbPath (`withSQLiteStore` action))

  describe "FR-26: persistence" $
    it "serves a paste after the store is closed and reopened" $
      withDbPath $ \path -> do
        let p = mkPaste "abcdEFGH" "survives restarts"
        withSQLiteStore path $ \s -> storeInsert s p `shouldReturn` Right ()
        withSQLiteStore path $ \s -> storeLookup s t0 (pasteId p) `shouldReturn` Found p

  describe "connection setup" $ do
    it "creates missing parent directories" $
      withDbPath $ \path ->
        withSQLiteStore path $ \s -> storePurgeExpired s t0 `shouldReturn` 0

    it "puts the database in WAL mode" $
      withDbPath $ \path -> do
        withSQLiteStore path $ \_ -> pure ()
        withConnection path $ \conn ->
          query_ conn "PRAGMA journal_mode" `shouldReturn` [Only ("wal" :: Text)]
