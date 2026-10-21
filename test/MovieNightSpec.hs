module MovieNightSpec (spec) where

import MovieNight (appName)
import Test.Hspec

spec :: Spec
spec =
  describe "appName" $
    it "matches the executable name" $
      (appName :: String) `shouldBe` "movie-night"
