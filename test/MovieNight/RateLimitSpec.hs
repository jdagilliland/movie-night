module MovieNight.RateLimitSpec (spec) where

import Control.Monad (replicateM)
import Data.Time (addUTCTime)
import MovieNight.RateLimit
import MovieNight.StoreContract (t0)
import Test.Hspec

spec :: Spec
spec =
  describe "NFR-5: RateLimiter" $ do
    it "allows up to the limit within the window, then refuses" $ do
      rl <- newRateLimiter 3 60
      replicateM 3 (allow rl "alice" t0) `shouldReturn` [True, True, True]
      allow rl "alice" (addUTCTime 59 t0) `shouldReturn` False

    it "allows again once earlier requests leave the window" $ do
      rl <- newRateLimiter 1 60
      allow rl "alice" t0 `shouldReturn` True
      allow rl "alice" (addUTCTime 60 t0) `shouldReturn` True

    it "doesn't count refused requests" $ do
      rl <- newRateLimiter 1 60
      allow rl "alice" t0 `shouldReturn` True
      allow rl "alice" (addUTCTime 30 t0) `shouldReturn` False
      -- The first request has left the window; the refused one never entered it.
      allow rl "alice" (addUTCTime 61 t0) `shouldReturn` True

    it "limits each user separately" $ do
      rl <- newRateLimiter 1 60
      allow rl "alice" t0 `shouldReturn` True
      allow rl "bob" t0 `shouldReturn` True
