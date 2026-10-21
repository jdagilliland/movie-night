-- | Behaviour every 'Store' implementation must satisfy. Each implementation's
-- spec runs this suite against a fresh store.
module MovieNight.StoreContract
  ( storeContract
  ) where

import Data.Maybe (fromJust)
import Data.Text (Text)
import Data.Time (UTCTime (..), addUTCTime, fromGregorian, nominalDay)
import MovieNight.Paste
import MovieNight.PasteId
import MovieNight.Store
import Test.Hspec

t0 :: UTCTime
t0 = UTCTime (fromGregorian 2026 10 21) 0

-- | A paste created at 't0' that lives for 30 days.
mkPaste :: Text -> Text -> Paste
mkPaste pid content =
  Paste
    { pasteId = fromJust (parsePasteId pid)
    , pasteContent = content
    , pasteCreatedBy = "alice"
    , pasteCreatedAt = t0
    , pasteExpiresAt = addUTCTime (30 * nominalDay) t0
    }

storeContract :: IO Store -> Spec
storeContract newStore = before newStore $ do
  let p = mkPaste "abcdEFGH" "hello\nworld"
      other = mkPaste "12345678" "other"
      expiry = pasteExpiresAt p

  describe "storeInsert / storeLookup" $ do
    it "returns an inserted paste unchanged" $ \s -> do
      storeInsert s p `shouldReturn` Right ()
      storeLookup s t0 (pasteId p) `shouldReturn` Found p

    it "returns NotFound for an unknown ID" $ \s ->
      storeLookup s t0 (pasteId p) `shouldReturn` NotFound

    it "keeps pastes separate" $ \s -> do
      _ <- storeInsert s p
      _ <- storeInsert s other
      storeLookup s t0 (pasteId other) `shouldReturn` Found other

    it "FR-10: rejects a duplicate ID" $ \s -> do
      _ <- storeInsert s p
      storeInsert s (mkPaste "abcdEFGH" "different") `shouldReturn` Left DuplicateId

    it "FR-10: rejects an ID already used by a taken-down paste" $ \s -> do
      _ <- storeInsert s p
      _ <- storeTakedown s (pasteId p) "spam" t0
      storeInsert s (mkPaste "abcdEFGH" "different") `shouldReturn` Left DuplicateId

  describe "FR-20: expiry at read time" $ do
    it "serves a paste just before it expires" $ \s -> do
      _ <- storeInsert s p
      storeLookup s (addUTCTime (-1) expiry) (pasteId p) `shouldReturn` Found p

    it "returns NotFound at the expiry instant" $ \s -> do
      _ <- storeInsert s p
      storeLookup s expiry (pasteId p) `shouldReturn` NotFound

    it "returns NotFound after expiry, even before a purge" $ \s -> do
      _ <- storeInsert s p
      storeLookup s (addUTCTime nominalDay expiry) (pasteId p) `shouldReturn` NotFound

  describe "FR-24, FR-25: storeTakedown" $ do
    it "makes the paste Gone" $ \s -> do
      _ <- storeInsert s p
      storeTakedown s (pasteId p) "spam" t0 `shouldReturn` TakenDown
      storeLookup s t0 (pasteId p) `shouldReturn` Gone

    it "reports AlreadyTakenDown on a repeat takedown" $ \s -> do
      _ <- storeInsert s p
      _ <- storeTakedown s (pasteId p) "spam" t0
      storeTakedown s (pasteId p) "again" t0 `shouldReturn` AlreadyTakenDown

    it "reports NoSuchPaste for an unknown ID" $ \s ->
      storeTakedown s (pasteId p) "spam" t0 `shouldReturn` NoSuchPaste

    it "leaves other pastes alone" $ \s -> do
      _ <- storeInsert s p
      _ <- storeInsert s other
      _ <- storeTakedown s (pasteId p) "spam" t0
      storeLookup s t0 (pasteId other) `shouldReturn` Found other

  describe "FR-21: storePurgeExpired" $ do
    it "removes only expired pastes and counts them" $ \s -> do
      let short = (mkPaste "shortTTL" "brief") {pasteExpiresAt = addUTCTime nominalDay t0}
      _ <- storeInsert s p
      _ <- storeInsert s short
      storePurgeExpired s (addUTCTime (2 * nominalDay) t0) `shouldReturn` 1
      storeLookup s t0 (pasteId p) `shouldReturn` Found p

    it "removes expired taken-down pastes, freeing their IDs" $ \s -> do
      _ <- storeInsert s p
      _ <- storeTakedown s (pasteId p) "spam" t0
      storePurgeExpired s expiry `shouldReturn` 1
      storeInsert s p `shouldReturn` Right ()

    it "returns 0 when nothing has expired" $ \s -> do
      _ <- storeInsert s p
      storePurgeExpired s t0 `shouldReturn` 0
