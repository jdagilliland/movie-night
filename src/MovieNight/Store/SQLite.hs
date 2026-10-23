-- | The SQLite-backed 'Store' (SPEC §7.3).
module MovieNight.Store.SQLite
  ( withSQLiteStore
  ) where

import Control.Concurrent.MVar (newMVar, withMVar)
import Control.Exception (bracket, handle)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time
  ( UTCTime (..)
  , defaultTimeLocale
  , formatTime
  , parseTimeM
  )
import Database.SQLite.Simple
  ( Connection
  , Only (..)
  , SQLError
  , changes
  , close
  , execute
  , execute_
  , open
  , query
  , query_
  )
import Database.SQLite.Simple.FromField (FromField (..), ResultError (..), returnError)
import Database.SQLite.Simple.ToField (ToField (..))
import Database.SQLite.Simple.Ok (Ok (..))
import MovieNight.Paste (Paste (..))
import MovieNight.PasteId (pasteIdText)
import MovieNight.Store
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory)

-- | Opens (creating if needed) the database at the given path, runs the
-- action with a 'Store' backed by it, and closes the database afterwards.
--
-- All access goes through a single connection guarded by a lock. Traffic is
-- expected to be very low (NFR-9), so serializing requests costs nothing
-- noticeable.
withSQLiteStore :: FilePath -> (Store -> IO a) -> IO a
withSQLiteStore path action = do
  createDirectoryIfMissing True (takeDirectory path)
  bracket (open path) close $ \conn -> do
    initialize conn
    lock <- newMVar conn
    action (sqliteStore (withMVar lock))

-- | Sets connection options and creates the schema if it doesn't exist yet.
initialize :: Connection -> IO ()
initialize conn = do
  -- WAL lets the admin CLI read and write while the server runs; the busy
  -- timeout makes either side wait briefly for the other's lock.
  _ <- query_ conn "PRAGMA journal_mode = WAL" :: IO [Only Text]
  execute_ conn "PRAGMA busy_timeout = 5000"
  execute_ conn
    "CREATE TABLE IF NOT EXISTS pastes (\
    \  id               TEXT PRIMARY KEY,\
    \  content          TEXT,\
    \  created_by       TEXT NOT NULL,\
    \  created_at       TEXT NOT NULL,\
    \  expires_at       TEXT NOT NULL,\
    \  taken_down_at    TEXT,\
    \  takedown_reason  TEXT\
    \)"
  execute_ conn "CREATE INDEX IF NOT EXISTS pastes_expires_at ON pastes(expires_at)"

sqliteStore :: (forall a. (Connection -> IO a) -> IO a) -> Store
sqliteStore withConn =
  Store
    { storeInsert = \p -> withConn $ \conn -> do
        execute conn
          "INSERT INTO pastes (id, content, created_by, created_at, expires_at)\
          \ VALUES (?, ?, ?, ?, ?) ON CONFLICT (id) DO NOTHING"
          ( pasteIdText (pasteId p)
          , pasteContent p
          , pasteCreatedBy p
          , Timestamp (pasteCreatedAt p)
          , Timestamp (pasteExpiresAt p)
          )
        inserted <- changes conn
        pure (if inserted == 1 then Right () else Left DuplicateId)
    , storeLookup = \now pid -> withConn $ \conn -> do
        rows <-
          query conn
            "SELECT content, created_by, created_at, expires_at, taken_down_at\
            \ FROM pastes WHERE id = ?"
            (Only (pasteIdText pid))
        pure $ case rows of
          [] -> NotFound
          (content, createdBy, Timestamp createdAt, Timestamp expiresAt, takenDownAt) : _
            | expiresAt <= now -> NotFound
            | Just (_ :: Timestamp) <- takenDownAt -> Gone
            | Just c <- content -> Found (Paste pid c createdBy createdAt expiresAt)
            -- Content is only ever NULL after a takedown, handled above.
            | otherwise -> NotFound
    , storeTakedown = \pid reason now -> withConn $ \conn -> do
        execute conn
          "UPDATE pastes SET content = NULL, taken_down_at = ?, takedown_reason = ?\
          \ WHERE id = ? AND taken_down_at IS NULL"
          (Timestamp now, reason, pasteIdText pid)
        updated <- changes conn
        if updated == 1
          then pure TakenDown
          else do
            existing <- query conn "SELECT 1 FROM pastes WHERE id = ?" (Only (pasteIdText pid))
            pure $ case existing :: [Only Int] of
              [] -> NoSuchPaste
              _ -> AlreadyTakenDown
    , storeInspect = \pid -> withConn $ \conn -> do
        rows <-
          query conn
            "SELECT created_by, created_at, expires_at, taken_down_at, takedown_reason\
            \ FROM pastes WHERE id = ?"
            (Only (pasteIdText pid))
        pure $ case rows of
          [] -> Nothing
          (createdBy, Timestamp createdAt, Timestamp expiresAt, takenDownAt, reason) : _ ->
            Just
              PasteInfo
                { infoCreatedBy = createdBy
                , infoCreatedAt = createdAt
                , infoExpiresAt = expiresAt
                , infoTakedown = Takedown <$> fmap (\(Timestamp t) -> t) takenDownAt <*> reason
                }
    , storePurgeExpired = \now -> withConn $ \conn -> do
        execute conn "DELETE FROM pastes WHERE expires_at <= ?" (Only (Timestamp now))
        changes conn
    , storeHealthy = withConn $ \conn ->
        handle (\(_ :: SQLError) -> pure False) $ do
          _ <- query_ conn "SELECT 1" :: IO [Only Int]
          pure True
    }

-- | A UTC time stored as ISO-8601 text at whole-second precision.
--
-- The fixed-width format makes text comparison in SQL order correctly
-- (variable-length fractions would sort @…00.5Z@ before @…00Z@). Writing
-- truncates towards the past, which never changes an expiry comparison:
-- expiry times are whole seconds, so @floor now >= expiresAt@ exactly when
-- @now >= expiresAt@.
newtype Timestamp = Timestamp UTCTime

timestampFormat :: String
timestampFormat = "%Y-%m-%dT%H:%M:%SZ"

instance ToField Timestamp where
  toField (Timestamp t) = toField (formatTime defaultTimeLocale timestampFormat t)

instance FromField Timestamp where
  fromField f = do
    s <- fromField f
    case parseTimeM False defaultTimeLocale timestampFormat (T.unpack s) of
      Just t -> Ok (Timestamp t)
      Nothing -> returnError ConversionFailed f ("malformed timestamp: " <> T.unpack s)
