module MovieNight.HtmlSpec (spec) where

import Data.Text qualified as T
import MovieNight.Html (MarqueeSize (..), marqueeSize)
import Test.Hspec

spec :: Spec
spec =
  describe "§8: marqueeSize" $ do
    it "makes a single line of up to 30 characters big" $ do
      marqueeSize "Alien" `shouldBe` Just Big
      marqueeSize (T.replicate 30 "a") `shouldBe` Just Big

    it "makes a single line of 31 to 100 characters medium" $ do
      marqueeSize (T.replicate 31 "a") `shouldBe` Just Medium
      marqueeSize (T.replicate 100 "a") `shouldBe` Just Medium

    it "shows a single line over 100 characters as text" $
      marqueeSize (T.replicate 101 "a") `shouldBe` Nothing

    it "shows anything with a line break as text" $ do
      marqueeSize "Alien\nAliens" `shouldBe` Nothing
      marqueeSize "Alien\n\nAliens" `shouldBe` Nothing

    it "ignores surrounding whitespace, including newlines" $ do
      marqueeSize "\n  Alien  \n" `shouldBe` Just Big
      marqueeSize ("  " <> T.replicate 30 "a" <> "\n") `shouldBe` Just Big

    it "counts characters, not bytes" $
      marqueeSize (T.replicate 30 "千") `shouldBe` Just Big
