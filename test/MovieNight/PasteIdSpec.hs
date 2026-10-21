module MovieNight.PasteIdSpec (spec) where

import Control.Monad (replicateM)
import Data.List (group, sort)
import Data.Maybe (isJust, mapMaybe)
import Data.Text qualified as T
import MovieNight.PasteId
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

spec :: Spec
spec = do
  describe "FR-8: base62 alphabet" $ do
    it "has 62 distinct characters" $
      length (group (sort base62Alphabet)) `shouldBe` 62

    it "maps accepted bytes uniformly: each character from exactly 4 bytes" $
      map length (group (sort (mapMaybe byteToBase62 [minBound .. maxBound])))
        `shouldBe` replicate 62 4

    it "rejects exactly the 8 bytes that would bias the distribution" $
      filter (not . isJust . byteToBase62) [minBound .. maxBound]
        `shouldBe` [248 .. 255]

  describe "FR-8: parsePasteId" $ do
    it "accepts an 8-character base62 string" $
      fmap pasteIdText (parsePasteId "aZ09bY18") `shouldBe` Just "aZ09bY18"

    prop "rejects strings of the wrong length" $
      forAll (listOf (elements base62Alphabet) `suchThat` ((/= 8) . length)) $ \s ->
        parsePasteId (T.pack s) `shouldBe` Nothing

    prop "rejects strings containing a non-base62 character" $
      forAll (vectorOf 7 (elements base62Alphabet)) $ \s ->
        forAll (arbitrary `suchThat` (`notElem` base62Alphabet)) $ \c ->
          forAll (choose (0, 7)) $ \i ->
            let (prefix, suffix) = splitAt i s
             in parsePasteId (T.pack (prefix <> [c] <> suffix)) `shouldBe` Nothing

    it "rejects paths that must not be mistaken for IDs" $
      mapM_ (\p -> parsePasteId p `shouldBe` Nothing) ["healthz", "static", "auth", "raw"]

  describe "FR-9: generatePasteId" $ do
    it "produces IDs that parse" $ do
      ids <- replicateM 1000 generatePasteId
      mapM_ (\i -> parsePasteId (pasteIdText i) `shouldBe` Just i) ids

    it "does not repeat across 1000 generations" $ do
      ids <- replicateM 1000 generatePasteId
      length (group (sort ids)) `shouldBe` 1000
