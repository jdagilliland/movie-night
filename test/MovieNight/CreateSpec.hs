module MovieNight.CreateSpec (spec) where

import Data.Maybe (fromJust)
import Data.Text qualified as T
import Data.Time (addUTCTime, nominalDay)
import MovieNight.Create
import MovieNight.Paste
import MovieNight.PasteId
import MovieNight.Store
import MovieNight.Store.Memory (newMemoryStore)
import MovieNight.StoreContract (mkPaste, t0)
import Test.Hspec

ids :: [T.Text] -> [PasteId]
ids = map (fromJust . parsePasteId)

spec :: Spec
spec = do
  describe "FR-4, FR-5, FR-6: validateContent" $ do
    it "FR-4: rejects empty and whitespace-only text" $
      mapM_ (\t -> validateContent 100 t `shouldBe` Left EmptyContent) ["", "   ", "\r\n\t \n"]

    it "FR-6: normalizes line endings" $
      validateContent 100 "a\r\nb\rc" `shouldBe` Right "a\nb\nc"

    it "FR-5: accepts text of exactly the limit in UTF-8 bytes" $
      -- "é" is two bytes in UTF-8.
      validateContent 10 (T.replicate 5 "é") `shouldBe` Right (T.replicate 5 "é")

    it "FR-5: rejects text one byte over the limit" $
      validateContent 10 (T.replicate 5 "é" <> "x") `shouldBe` Left ContentTooLarge

    it "FR-5: measures the text after line-ending normalization" $
      -- 8 bytes as submitted, 6 as stored.
      validateContent 6 "ab\r\ncd\r\n" `shouldBe` Right "ab\ncd\n"

  describe "FR-2, FR-10, FR-19: createPaste" $ do
    it "stores the paste with whole-second times and the configured lifetime" $ do
      store <- newMemoryStore
      result <- createPaste store (ids ["abcdEFGH"]) (30 * nominalDay) "alice" (addUTCTime 0.5 t0) "hello"
      result `shouldBe` Right (fromJust (parsePasteId "abcdEFGH"))
      storeLookup store t0 (fromJust (parsePasteId "abcdEFGH"))
        `shouldReturn` Found (mkPaste "abcdEFGH" "hello")

    it "FR-10: retries when the generated ID is taken" $ do
      store <- newMemoryStore
      _ <- storeInsert store (mkPaste "takenAAA" "first")
      createPaste store (ids ["takenAAA", "takenAAA", "freeBBBB"]) nominalDay "alice" t0 "second"
        `shouldReturn` Right (fromJust (parsePasteId "freeBBBB"))

    it "FR-10: gives up after the first attempt plus 7 retries" $ do
      store <- newMemoryStore
      _ <- storeInsert store (mkPaste "takenAAA" "first")
      let candidates = ids (replicate maxIdAttempts "takenAAA" <> ["freeBBBB"])
      createPaste store candidates nominalDay "alice" t0 "second" `shouldReturn` Left NoFreeId
      maxIdAttempts `shouldBe` 8

    it "FR-10: stops on an endless supply of taken IDs" $ do
      store <- newMemoryStore
      _ <- storeInsert store (mkPaste "takenAAA" "first")
      createPaste store (repeat (fromJust (parsePasteId "takenAAA"))) nominalDay "alice" t0 "second"
        `shouldReturn` Left NoFreeId

    it "AUTH-3: records the creator" $ do
      store <- newMemoryStore
      _ <- createPaste store (ids ["abcdEFGH"]) nominalDay "bob" t0 "hi"
      result <- storeLookup store t0 (fromJust (parsePasteId "abcdEFGH"))
      case result of
        Found p -> pasteCreatedBy p `shouldBe` "bob"
        other -> expectationFailure ("expected Found, got " <> show other)
