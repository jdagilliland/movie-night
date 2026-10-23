{-# LANGUAGE LambdaCase #-}

-- | The admin CLI's operations (SPEC §6), separate from argument parsing so
-- they can be tested against any 'Store'. Each returns a message for the
-- admin, or an error that makes the command exit non-zero.
module MovieNight.Admin
  ( takedown
  , describePaste
  ) where

import Control.Exception (IOException, try)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime)
import MovieNight.Html (formatTimestamp)
import MovieNight.PasteId (PasteId, pasteIdText)
import MovieNight.Store
import MovieNight.TakedownLog (TakedownEntry (..), appendTakedown)

-- | FR-23–FR-25: erases a paste's content and logs the takedown. Takes the
-- takedown log path, the current time, the ID, and the reason.
takedown :: Store -> FilePath -> UTCTime -> PasteId -> Text -> IO (Either String Text)
takedown store logPath now pid rawReason
  | T.null reason = pure (Left "A takedown reason is required.")
  | otherwise =
      storeTakedown store pid reason now >>= \case
        TakenDown -> do
          -- The content is already erased, so a failure to log must not be
          -- silent: the log is the lasting record of the takedown.
          logged <- try (appendTakedown logPath (TakedownEntry (truncateToSecond now) pid reason))
          pure $ case logged of
            Right () -> Right ("Took down " <> idText <> ".")
            Left (e :: IOException) ->
              Left
                ( "Took down " <> T.unpack idText <> ", but could not write the takedown log at "
                    <> logPath <> ": " <> show e <> ". Record this takedown manually."
                )
        AlreadyTakenDown -> pure (Right (idText <> " was already taken down."))
        NoSuchPaste -> pure (Left ("No such paste: " <> T.unpack idText <> "."))
  where
    reason = T.strip rawReason
    idText = pasteIdText pid

-- | @show@: a paste's metadata and status, never its content.
describePaste :: Store -> UTCTime -> PasteId -> IO (Either String Text)
describePaste store now pid =
  storeInspect store pid >>= \case
    Nothing ->
      pure . Left $
        "No such paste: " <> T.unpack (pasteIdText pid)
          <> ". It never existed, or it expired and has been purged."
    Just info ->
      pure . Right . T.unlines $
        [ "id:          " <> pasteIdText pid
        , "status:      " <> status info
        , "created at:  " <> formatTimestamp (infoCreatedAt info)
        , "created by:  " <> infoCreatedBy info
        , "expires at:  " <> formatTimestamp (infoExpiresAt info)
        ]
          <> case infoTakedown info of
            Nothing -> []
            Just t ->
              [ "taken down:  " <> formatTimestamp (takedownAt t)
              , "reason:      " <> takedownReason t
              ]
  where
    status info
      | Just _ <- infoTakedown info = "taken down"
      | infoExpiresAt info <= now = "expired (not yet purged)"
      | otherwise = "live"
