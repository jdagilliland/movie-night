module Main (main) where

import Data.Time (getCurrentTime)
import MovieNight.Config (Config (..), loadConfig)
import MovieNight.Server (Env (..), app)
import MovieNight.Store.SQLite (withSQLiteStore)
import Network.Wai.Handler.Warp (run)
import Network.Wai.Middleware.RequestLogger (logStdout)
import Options.Applicative
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

data Command = Serve

commandParser :: Parser Command
commandParser =
  hsubparser
    (command "serve" (info (pure Serve) (progDesc "Run the web server")))

main :: IO ()
main = do
  cmd <- execParser (info (commandParser <**> helper) (progDesc "Movie Night: paste text, get a short link"))
  case cmd of
    Serve -> serve

serve :: IO ()
serve = do
  cfg <- loadConfig >>= either (\err -> hPutStrLn stderr err >> exitFailure) pure
  withSQLiteStore (cfgDbPath cfg) $ \store -> do
    let env = Env {envStore = store, envBaseUrl = cfgBaseUrl cfg, envNow = getCurrentTime}
    putStrLn ("Listening on port " <> show (cfgPort cfg))
    -- NFR-11: Apache-format request log; bodies are never logged.
    run (cfgPort cfg) (logStdout (app env))
