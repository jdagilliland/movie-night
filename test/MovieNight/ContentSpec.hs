module MovieNight.ContentSpec (spec) where

import Data.Text qualified as T
import MovieNight.Content
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

-- | Text biased towards line-ending characters.
newtype Lines = Lines String
  deriving stock (Show)

instance Arbitrary Lines where
  arbitrary = Lines <$> listOf (frequency [(3, elements "\r\n"), (1, arbitrary)])

spec :: Spec
spec =
  describe "FR-6: normalizeLineEndings" $ do
    it "converts CRLF to LF" $
      normalizeLineEndings "a\r\nb\r\n" `shouldBe` "a\nb\n"

    it "converts a lone CR to LF" $
      normalizeLineEndings "a\rb" `shouldBe` "a\nb"

    it "treats CR CR LF as two line breaks" $
      normalizeLineEndings "\r\r\n" `shouldBe` "\n\n"

    prop "leaves no CR behind" $ \(Lines s) ->
      T.any (== '\r') (normalizeLineEndings (T.pack s)) `shouldBe` False

    prop "is idempotent" $ \(Lines s) ->
      let normalized = normalizeLineEndings (T.pack s)
       in normalizeLineEndings normalized `shouldBe` normalized

    prop "leaves text without CR unchanged" $ \s ->
      let t = T.pack (filter (/= '\r') s)
       in normalizeLineEndings t `shouldBe` t
