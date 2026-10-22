-- | An in-memory 'Store', for tests.
module MovieNight.Store.Memory
  ( newMemoryStore
  ) where

import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Time (UTCTime)
import MovieNight.Paste (Paste (..))
import MovieNight.PasteId (PasteId)
import MovieNight.Store

data Entry = Entry
  { entryPaste :: Paste
  -- ^ Content is blanked once taken down.
  , entryTakedown :: Maybe (UTCTime, Text)
  }

newMemoryStore :: IO Store
newMemoryStore = do
  ref <- newIORef (Map.empty :: Map PasteId Entry)
  let modify = atomicModifyIORef' ref
  pure
    Store
      { storeInsert = \paste -> modify $ \m ->
          let stored =
                paste
                  { pasteCreatedAt = truncateToSecond (pasteCreatedAt paste)
                  , pasteExpiresAt = truncateToSecond (pasteExpiresAt paste)
                  }
           in if Map.member (pasteId paste) m
                then (m, Left DuplicateId)
                else (Map.insert (pasteId paste) (Entry stored Nothing) m, Right ())
      , storeLookup = \now pid -> do
          m <- readIORef ref
          pure $ case Map.lookup pid m of
            Nothing -> NotFound
            Just e
              | pasteExpiresAt (entryPaste e) <= now -> NotFound
              | Just _ <- entryTakedown e -> Gone
              | otherwise -> Found (entryPaste e)
      , storeTakedown = \pid reason now -> modify $ \m ->
          case Map.lookup pid m of
            Nothing -> (m, NoSuchPaste)
            Just (Entry _ (Just _)) -> (m, AlreadyTakenDown)
            Just (Entry p Nothing) ->
              ( Map.insert pid (Entry p {pasteContent = ""} (Just (now, reason))) m
              , TakenDown
              )
      , storePurgeExpired = \now -> modify $ \m ->
          let (expired, kept) = Map.partition ((<= now) . pasteExpiresAt . entryPaste) m
           in (kept, Map.size expired)
      }
