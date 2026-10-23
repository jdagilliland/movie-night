-- | Per-user rate limiting for paste creation (NFR-5).
module MovieNight.RateLimit
  ( RateLimiter
  , newRateLimiter
  , allow
  ) where

import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Time (NominalDiffTime, UTCTime, addUTCTime)

-- | A sliding window: at most a fixed number of requests per key within any
-- window of the given length. State lives in memory and resets on restart.
data RateLimiter = RateLimiter
  { rlLimit :: Int
  , rlWindow :: NominalDiffTime
  , rlHits :: IORef (Map Text [UTCTime])
  }

newRateLimiter :: Int -> NominalDiffTime -> IO RateLimiter
newRateLimiter limit window = RateLimiter limit window <$> newIORef Map.empty

-- | Records a request for the key at the given time, if it is within the
-- limit, and reports whether it was.
allow :: RateLimiter -> Text -> UTCTime -> IO Bool
allow rl key now = atomicModifyIORef' (rlHits rl) $ \hits ->
  let cutoff = addUTCTime (negate (rlWindow rl)) now
      recent = filter (> cutoff) (Map.findWithDefault [] key hits)
   in if length recent < rlLimit rl
        then (Map.insert key (now : recent) hits, True)
        else (Map.insert key recent hits, False)
