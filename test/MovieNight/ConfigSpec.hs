module MovieNight.ConfigSpec (spec) where

import Data.Either (isLeft)
import MovieNight.Config
import Test.Hspec

parseWith :: [(String, String)] -> Either String Config
parseWith vars = parseConfig (`lookup` vars)

spec :: Spec
spec =
  describe "§7.4: parseConfig" $ do
    it "applies defaults for unset variables" $
      parseWith []
        `shouldBe` Right (Config 8080 "./data/pastes.db" "http://localhost:8080")

    it "reads every variable" $
      parseWith [("PORT", "9000"), ("DB_PATH", "/data/db/pastes.db"), ("BASE_URL", "https://example.com")]
        `shouldBe` Right (Config 9000 "/data/db/pastes.db" "https://example.com")

    it "strips trailing slashes from BASE_URL" $
      cfgBaseUrl <$> parseWith [("BASE_URL", "https://example.com//")]
        `shouldBe` Right "https://example.com"

    it "rejects a non-numeric or out-of-range PORT" $
      mapM_ (\p -> parseWith [("PORT", p)] `shouldSatisfy` isLeft) ["http", "0", "65536", ""]
