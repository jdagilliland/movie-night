-- | The storage interface handlers depend on (SPEC §7.2).
module MovieNight.Store
  ( Store (..)
  , LookupResult (..)
  , InsertError (..)
  , TakedownResult (..)
  ) where

import Data.Text (Text)
import Data.Time (UTCTime)
import MovieNight.Paste (Paste)
import MovieNight.PasteId (PasteId)

data LookupResult
  = Found Paste
  | Gone
  -- ^ Taken down; served as 404 publicly (FR-17).
  | NotFound
  -- ^ Never existed or expired; served as 404 (FR-16).
  deriving stock (Eq, Show)

data InsertError
  = DuplicateId
  -- ^ The ID is already used, including by a taken-down paste (FR-10).
  deriving stock (Eq, Show)

data TakedownResult
  = TakenDown
  | AlreadyTakenDown
  | NoSuchPaste
  deriving stock (Eq, Show)

-- | Every operation that depends on the current time takes it as an argument,
-- so expiry is testable without a clock.
data Store = Store
  { storeInsert :: Paste -> IO (Either InsertError ())
  , storeLookup :: UTCTime -> PasteId -> IO LookupResult
  -- ^ FR-20: a paste is served only while @now < expiresAt@.
  , storeTakedown :: PasteId -> Text -> UTCTime -> IO TakedownResult
  -- ^ FR-24: erases content; arguments are the reason and the takedown time.
  , storePurgeExpired :: UTCTime -> IO Int
  -- ^ FR-21: deletes every paste with @expiresAt <= now@, returning the count.
  }
