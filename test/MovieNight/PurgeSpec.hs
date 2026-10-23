module MovieNight.PurgeSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (withAsync)
import Control.Monad (when)
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Data.List (isPrefixOf)
import MovieNight.Purge (purgeEvery)
import MovieNight.Store
import MovieNight.Store.Memory (newMemoryStore)
import MovieNight.StoreContract (t0)
import System.Timeout (timeout)
import Test.Hspec

-- | A memory store whose purge counts its calls and fails on the calls
-- listed.
countingStore :: [Int] -> IO (Store, IORef Int)
countingStore failOn = do
  store <- newMemoryStore
  calls <- newIORef 0
  let purge now = do
        n <- atomicModifyIORef' calls (\c -> (c + 1, c + 1))
        when (n `elem` failOn) $ ioError (userError "database is locked")
        storePurgeExpired store now
  pure (store {storePurgeExpired = purge}, calls)

-- | Waits up to two seconds for a condition, failing the test otherwise.
eventually :: IO Bool -> Expectation
eventually check = do
  result <- timeout 2000000 loop
  result `shouldBe` Just ()
  where
    loop = do
      ok <- check
      if ok then pure () else threadDelay 1000 >> loop

spec :: Spec
spec =
  describe "FR-21: purgeEvery" $ do
    it "purges immediately and then repeatedly, reporting each result" $ do
      (store, calls) <- countingStore []
      reports <- newIORef []
      let report r = modifyIORef' reports (r :)
      -- A long interval: only the immediate purge should happen. Waiting on
      -- the report, not the call count, ensures it was written before the
      -- loop is cancelled.
      withAsync (purgeEvery 60000000 store (pure t0) report) $ \_ ->
        eventually (not . null <$> readIORef reports)
      readIORef reports `shouldReturn` ["Purged 0 expired paste(s)."]
      readIORef calls `shouldReturn` 1
      -- A short interval: purges keep coming.
      withAsync (purgeEvery 1000 store (pure t0) report) $ \_ ->
        eventually ((>= 4) <$> readIORef calls)

    it "reports a failed purge and keeps going" $ do
      (store, _) <- countingStore [1]
      reports <- newIORef []
      withAsync (purgeEvery 1000 store (pure t0) (\r -> modifyIORef' reports (r :))) $ \_ ->
        eventually ((>= 2) . length <$> readIORef reports)
      rs <- reverse <$> readIORef reports
      take 1 rs `shouldSatisfy` all ("Purge failed:" `isPrefixOf`)
      drop 1 rs `shouldSatisfy` all ("Purged " `isPrefixOf`)
