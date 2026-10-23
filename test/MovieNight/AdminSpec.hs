module MovieNight.AdminSpec (spec) where

import Data.Either (isLeft)
import Data.Maybe (fromJust)
import Data.Text qualified as T
import Data.Time (UTCTime, addUTCTime, nominalDay)
import MovieNight.Admin
import MovieNight.Paste
import MovieNight.PasteId (PasteId, parsePasteId)
import MovieNight.Store
import MovieNight.Store.Memory (newMemoryStore)
import MovieNight.StoreContract (mkPaste, t0)
import MovieNight.TakedownLog (TakedownEntry (..), readTakedownLog)
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

p :: Paste
p = mkPaste "abcdEFGH" "secret content"

unknown :: PasteId
unknown = fromJust (parsePasteId "zzzzzzzz")

-- | A store holding 'p', and a takedown log path in a fresh directory.
withFixture :: (Store -> FilePath -> IO a) -> IO a
withFixture action = withSystemTempDirectory "movie-night" $ \dir -> do
  store <- newMemoryStore
  _ <- storeInsert store p
  action store (dir </> "logs" </> "takedowns.log")

-- | One hour in, with fractional seconds that the log should drop.
now :: UTCTime
now = addUTCTime 3600.25 t0

spec :: Spec
spec = do
  describe "FR-23–FR-25: takedown" $ do
    it "erases the paste, logs the takedown, and reports it" $
      withFixture $ \store logPath -> do
        takedown store logPath now (pasteId p) "spam" `shouldReturn` Right "Took down abcdEFGH."
        storeLookup store now (pasteId p) `shouldReturn` Gone
        readTakedownLog logPath
          `shouldReturn` Right [TakedownEntry (addUTCTime 3600 t0) (pasteId p) "spam"]

    it "is idempotent: a repeat succeeds without logging again" $
      withFixture $ \store logPath -> do
        _ <- takedown store logPath now (pasteId p) "spam"
        takedown store logPath now (pasteId p) "again"
          `shouldReturn` Right "abcdEFGH was already taken down."
        fmap length <$> readTakedownLog logPath `shouldReturn` Right 1

    it "fails for an unknown paste, logging nothing" $
      withFixture $ \store logPath -> do
        takedown store logPath now unknown "spam" >>= (`shouldSatisfy` isLeft)
        doesFileExist logPath `shouldReturn` False

    it "requires a non-blank reason, and trims it" $
      withFixture $ \store logPath -> do
        takedown store logPath now (pasteId p) "  " >>= (`shouldSatisfy` isLeft)
        storeLookup store now (pasteId p) `shouldReturn` Found p
        _ <- takedown store logPath now (pasteId p) "  spam \n"
        fmap (map entryReason) <$> readTakedownLog logPath `shouldReturn` Right ["spam"]

    it "reports a log failure loudly, after the content is already erased" $
      withFixture $ \store _ -> do
        -- A directory can't be appended to.
        result <- takedown store "/" now (pasteId p) "spam"
        either (T.isInfixOf "Record this takedown manually" . T.pack) (const False) result
          `shouldBe` True
        storeLookup store now (pasteId p) `shouldReturn` Gone

  describe "§6: show" $ do
    it "describes a live paste, without its content" $
      withFixture $ \store _ -> do
        Right out <- describePaste store now (pasteId p)
        T.lines out
          `shouldBe` [ "id:          abcdEFGH"
                     , "status:      live"
                     , "created at:  2026-10-21 00:00:00 UTC"
                     , "created by:  alice"
                     , "expires at:  2026-11-20 00:00:00 UTC"
                     ]
        out `shouldNotSatisfy` T.isInfixOf "secret content"

    it "includes the takedown time and reason" $
      withFixture $ \store logPath -> do
        _ <- takedown store logPath now (pasteId p) "spam"
        Right out <- describePaste store now (pasteId p)
        T.lines out `shouldContain` ["status:      taken down"]
        T.lines out `shouldContain` ["taken down:  2026-10-21 01:00:00 UTC", "reason:      spam"]

    it "marks an expired, not yet purged paste" $
      withFixture $ \store _ -> do
        Right out <- describePaste store (addUTCTime (31 * nominalDay) t0) (pasteId p)
        T.lines out `shouldContain` ["status:      expired (not yet purged)"]

    it "fails for an unknown paste" $
      withFixture $ \store _ ->
        describePaste store now unknown >>= (`shouldSatisfy` isLeft)
