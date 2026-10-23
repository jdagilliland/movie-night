-- | The background purge of expired pastes (FR-21).
module MovieNight.Purge
  ( purgeEvery
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeAsyncException, SomeException, fromException, handle, throwIO)
import Control.Monad (forever)
import Data.Time (UTCTime)
import MovieNight.Store

-- | Purges expired pastes immediately and then after every interval (in
-- microseconds), forever, reporting each result. A failed purge is reported
-- and retried at the next interval rather than ending the loop.
purgeEvery :: Int -> Store -> IO UTCTime -> (String -> IO ()) -> IO a
purgeEvery interval store getNow report = forever $ do
  handle onError $ do
    purged <- getNow >>= storePurgeExpired store
    report ("Purged " <> show purged <> " expired paste(s).")
  threadDelay interval
  where
    -- Asynchronous exceptions (e.g. the thread being cancelled) must
    -- propagate, or the loop could never be stopped.
    onError :: SomeException -> IO ()
    onError e = case fromException e :: Maybe SomeAsyncException of
      Just _ -> throwIO e
      Nothing -> report ("Purge failed: " <> show e)
