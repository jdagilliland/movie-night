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
        `shouldBe` Right
          Config
            { cfgPort = 8080
            , cfgDbPath = "./data/pastes.db"
            , cfgBaseUrl = "http://localhost:8080"
            , cfgMaxPasteBytes = 524288
            , cfgPasteTtlDays = 30
            , cfgAuthUsersFile = "./data/users"
            }

    it "reads every variable" $
      parseWith
        [ ("PORT", "9000")
        , ("DB_PATH", "/data/db/pastes.db")
        , ("BASE_URL", "https://example.com")
        , ("MAX_PASTE_BYTES", "1024")
        , ("PASTE_TTL_DAYS", "7")
        , ("AUTH_USERS_FILE", "/data/users")
        ]
        `shouldBe` Right
          Config
            { cfgPort = 9000
            , cfgDbPath = "/data/db/pastes.db"
            , cfgBaseUrl = "https://example.com"
            , cfgMaxPasteBytes = 1024
            , cfgPasteTtlDays = 7
            , cfgAuthUsersFile = "/data/users"
            }

    it "strips trailing slashes from BASE_URL" $
      cfgBaseUrl <$> parseWith [("BASE_URL", "https://example.com//")]
        `shouldBe` Right "https://example.com"

    it "rejects a non-numeric or out-of-range PORT" $
      mapM_ (\p -> parseWith [("PORT", p)] `shouldSatisfy` isLeft) ["http", "0", "65536", ""]

    it "rejects a non-positive MAX_PASTE_BYTES or PASTE_TTL_DAYS" $
      mapM_
        (\var -> parseWith [var] `shouldSatisfy` isLeft)
        [("MAX_PASTE_BYTES", "0"), ("PASTE_TTL_DAYS", "-1"), ("PASTE_TTL_DAYS", "a week")]
