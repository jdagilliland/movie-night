module Main (main) where

import Control.Concurrent.Async (withAsync)
import Control.Exception (bracket_)
import Control.Monad (unless, when)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time (getCurrentTime, nominalDay)
import MovieNight.Admin (describePaste, takedown)
import MovieNight.Config (Config (..), loadConfig)
import MovieNight.PasteId (PasteId, generatePasteId, parsePasteId)
import MovieNight.Purge (purgeEvery)
import MovieNight.RateLimit (newRateLimiter)
import MovieNight.Server (Env (..), app)
import MovieNight.Store (Store, storePurgeExpired)
import MovieNight.Store.SQLite (withSQLiteStore)
import MovieNight.Users
import Network.Wai.Handler.Warp (run)
import Network.Wai.Middleware.RequestLogger
  ( IPAddrSource (..)
  , OutputFormat (..)
  , defaultRequestLoggerSettings
  , mkRequestLogger
  , outputFormat
  )
import Options.Applicative
import System.Directory (doesFileExist)
import System.Exit (exitFailure)
import System.IO

data Command
  = Serve
  | Takedown Text Text
  | Show Text
  | PurgeExpired
  | AddUser Text
  | SetPassword Text
  | RemoveUser Text

commandParser :: Parser Command
commandParser =
  hsubparser $
    mconcat
      [ command "serve" (info (pure Serve) (progDesc "Run the web server"))
      , command "takedown" $
          info
            (Takedown <$> idArg <*> strOption (long "reason" <> metavar "TEXT" <> help "Why the paste is taken down (logged)"))
            (progDesc "Erase a paste's content and log the takedown")
      , command "show" (info (Show <$> idArg) (progDesc "Print a paste's metadata and status"))
      , command "purge-expired" (info (pure PurgeExpired) (progDesc "Delete expired pastes now"))
      , command "add-user" (info (AddUser <$> nameArg) (progDesc "Add a user; prompts for a password"))
      , command "set-password" (info (SetPassword <$> nameArg) (progDesc "Replace a user's password; prompts for it"))
      , command "remove-user" (info (RemoveUser <$> nameArg) (progDesc "Remove a user; their pastes are unaffected"))
      ]
  where
    idArg = strArgument (metavar "ID")
    nameArg = strArgument (metavar "NAME")

main :: IO ()
main = do
  cmd <- execParser (info (commandParser <**> helper) (progDesc "Movie Night: paste text, get a short link"))
  cfg <- loadConfig >>= orDie
  case cmd of
    Serve -> serve cfg
    Takedown idText reason -> do
      pid <- pasteIdArg idText
      withExistingStore cfg $ \store -> do
        now <- getCurrentTime
        takedown store (cfgTakedownLog cfg) now pid reason >>= orDie >>= TIO.putStrLn
    Show idText -> do
      pid <- pasteIdArg idText
      withExistingStore cfg $ \store -> do
        now <- getCurrentTime
        describePaste store now pid >>= orDie >>= TIO.putStr
    PurgeExpired ->
      withExistingStore cfg $ \store -> do
        purged <- getCurrentTime >>= storePurgeExpired store
        putStrLn ("Purged " <> show purged <> " expired paste(s).")
    AddUser name -> do
      user <- username name
      exists <- doesFileExist (cfgAuthUsersFile cfg)
      when exists $ do
        users <- loadUsersFile (cfgAuthUsersFile cfg) >>= orDie
        when (Map.member user users) $ die' ("user " <> show name <> " already exists")
      hash <- promptNewPassword >>= hashPassword
      addUser (cfgAuthUsersFile cfg) user hash >>= orDie
      putStrLn ("Added user " <> T.unpack name <> ". " <> restartNote)
    SetPassword name -> do
      user <- username name
      users <- loadUsersFile (cfgAuthUsersFile cfg) >>= orDie
      unless (Map.member user users) $ die' ("no such user " <> show name)
      hash <- promptNewPassword >>= hashPassword
      setPassword (cfgAuthUsersFile cfg) user hash >>= orDie
      putStrLn ("Changed the password for " <> T.unpack name <> ". " <> restartNote)
    RemoveUser name -> do
      user <- username name
      removeUser (cfgAuthUsersFile cfg) user >>= orDie
      putStrLn ("Removed user " <> T.unpack name <> ". " <> restartNote)
  where
    username name = maybe (die' "Usernames must match [a-z0-9_-]{1,32}.") pure (parseUsername name)
    restartNote = "Restart the server for the change to take effect."

pasteIdArg :: Text -> IO PasteId
pasteIdArg t = maybe (die' ("Malformed paste ID: " <> show t)) pure (parsePasteId t)

-- | Opens the database for an admin command. Unlike the server, this refuses
-- to create a missing database: a wrong DB_PATH would otherwise silently
-- report every paste as missing.
withExistingStore :: Config -> (Store -> IO a) -> IO a
withExistingStore cfg useStore = do
  exists <- doesFileExist (cfgDbPath cfg)
  unless exists $ die' ("Database not found: " <> cfgDbPath cfg <> " (check DB_PATH)")
  withSQLiteStore (cfgDbPath cfg) useStore

serve :: Config -> IO ()
serve cfg = do
  -- Output goes to container logs; flush each line rather than each block.
  hSetBuffering stdout LineBuffering
  users <- loadUsersFile (cfgAuthUsersFile cfg) >>= orDie
  rateLimiter <- newRateLimiter 30 60 -- NFR-5: 30 pastes per user per minute
  -- NFR-11: Apache-format request log; bodies are never logged. Behind
  -- Caddy, the client address comes from X-Forwarded-For, which Caddy sets
  -- itself (discarding any value the client sent); without a proxy, the
  -- socket address is used.
  requestLogger <-
    mkRequestLogger defaultRequestLoggerSettings {outputFormat = Apache FromFallback}
  withSQLiteStore (cfgDbPath cfg) $ \store -> do
    let env =
          Env
            { envStore = store
            , envBaseUrl = cfgBaseUrl cfg
            , envNow = getCurrentTime
            , envGenerateId = generatePasteId
            , envUsers = users
            , envPasteTtl = fromIntegral (cfgPasteTtlDays cfg) * nominalDay
            , envMaxPasteBytes = cfgMaxPasteBytes cfg
            , envRateLimiter = rateLimiter
            }
    -- FR-21: purge at startup, then daily, for as long as the server runs.
    withAsync (purgeEvery (24 * 60 * 60 * 1000000) store getCurrentTime putStrLn) $ \_ -> do
      putStrLn ("Listening on port " <> show (cfgPort cfg))
      run (cfgPort cfg) (requestLogger (app env))

-- | Reads a password twice without echoing it. Input that isn't a terminal
-- (e.g. a pipe) is read as-is, one line per prompt.
promptNewPassword :: IO Text
promptNewPassword = do
  password <- readHidden "Password: "
  confirmation <- readHidden "Repeat password: "
  when (password /= confirmation) $ die' "Passwords do not match."
  when (T.null password) $ die' "The password must not be empty."
  pure password
  where
    readHidden prompt = do
      putStr prompt
      hFlush stdout
      terminal <- hIsTerminalDevice stdin
      line <-
        if terminal
          then bracket_ (hSetEcho stdin False) (hSetEcho stdin True) getLine <* putStrLn ""
          else getLine
      pure (T.pack line)

orDie :: Either String a -> IO a
orDie = either die' pure

die' :: String -> IO a
die' msg = hPutStrLn stderr msg >> exitFailure
