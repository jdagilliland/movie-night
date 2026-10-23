module MovieNight.TakedownLogSpec (spec) where

import Data.ByteString.Char8 qualified as BC
import Data.Either (isLeft)
import Data.Maybe (fromJust)
import Data.Time (addUTCTime)
import MovieNight.PasteId (parsePasteId)
import MovieNight.StoreContract (t0)
import MovieNight.TakedownLog
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

withLogPath :: (FilePath -> IO a) -> IO a
withLogPath action = withSystemTempDirectory "movie-night" $ \dir -> action (dir </> "logs" </> "takedowns.log")

entry :: TakedownEntry
entry = TakedownEntry t0 (fromJust (parsePasteId "abcdEFGH")) "spam"

spec :: Spec
spec =
  describe "§6: the takedown log" $ do
    it "appends entries in order, creating the file and directory" $
      withLogPath $ \path -> do
        let second = entry {entryTime = addUTCTime 60 t0, entryReason = "abuse"}
        appendTakedown path entry
        appendTakedown path second
        readTakedownLog path `shouldReturn` Right [entry, second]

    it "writes one JSON object per line, with a UTC timestamp" $
      withLogPath $ \path -> do
        appendTakedown path entry
        BC.readFile path
          `shouldReturn` "{\"id\":\"abcdEFGH\",\"reason\":\"spam\",\"time\":\"2026-10-21T00:00:00Z\"}\n"

    it "keeps a reason containing newlines on one line" $
      withLogPath $ \path -> do
        let multiline = entry {entryReason = "line one\nline two"}
        appendTakedown path multiline
        contents <- BC.readFile path
        length (BC.lines contents) `shouldBe` 1
        readTakedownLog path `shouldReturn` Right [multiline]

    it "reports a malformed line by number" $
      withLogPath $ \path -> do
        appendTakedown path entry
        BC.appendFile path "not json\n"
        result <- readTakedownLog path
        result `shouldSatisfy` isLeft
        either (take 7) (const "") result `shouldBe` "line 2:"
