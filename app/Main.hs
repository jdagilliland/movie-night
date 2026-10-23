module Main (main) where

import Control.Exception (bracket_)
import Control.Monad (unless, when)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (getCurrentTime, nominalDay)
import MovieNight.Config (Config (..), loadConfig)
import MovieNight.PasteId (generatePasteId)
import MovieNight.RateLimit (newRateLimiter)
import MovieNight.Server (Env (..), app)
import MovieNight.Store.SQLite (withSQLiteStore)
import MovieNight.Users
import Network.Wai.Handler.Warp (run)
import Network.Wai.Middleware.RequestLogger (logStdout)
import Options.Applicative
import System.Directory (doesFileExist)
import System.Exit (exitFailure)
import System.IO

data Command
  = Serve
  | AddUser Text
  | SetPassword Text
  | RemoveUser Text

commandParser :: Parser Command
commandParser =
  hsubparser $
    mconcat
      [ command "serve" (info (pure Serve) (progDesc "Run the web server"))
      , command "add-user" (info (AddUser <$> nameArg) (progDesc "Add a user; prompts for a password"))
      , command "set-password" (info (SetPassword <$> nameArg) (progDesc "Replace a user's password; prompts for it"))
      , command "remove-user" (info (RemoveUser <$> nameArg) (progDesc "Remove a user; their pastes are unaffected"))
      ]
  where
    nameArg = strArgument (metavar "NAME")

main :: IO ()
main = do
  cmd <- execParser (info (commandParser <**> helper) (progDesc "Movie Night: paste text, get a short link"))
  cfg <- loadConfig >>= orDie
  case cmd of
    Serve -> serve cfg
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

serve :: Config -> IO ()
serve cfg = do
  users <- loadUsersFile (cfgAuthUsersFile cfg) >>= orDie
  rateLimiter <- newRateLimiter 30 60 -- NFR-5: 30 pastes per user per minute
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
    putStrLn ("Listening on port " <> show (cfgPort cfg))
    -- NFR-11: Apache-format request log; bodies are never logged.
    run (cfgPort cfg) (logStdout (app env))

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
