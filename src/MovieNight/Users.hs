-- | Interim users and passwords (SPEC §5.3).
module MovieNight.Users
  ( -- * Usernames
    Username
  , usernameText
  , parseUsername
  , User (..)
    -- * Password hashes
  , HashParams (..)
  , defaultHashParams
  , PasswordHash
  , hashPassword
  , hashPasswordWith
  , verifyPassword
  , renderPasswordHash
  , parsePasswordHash
    -- * The users file
  , Users
  , authenticate
  , parseUsersFile
  , loadUsersFile
  , addUser
  , setPassword
  , removeUser
  ) where

import Control.Monad (unless, when)
import Crypto.KDF.Argon2 qualified as Argon2
import Crypto.Error (CryptoFailable (..))
import Crypto.Random (getRandomBytes)
import Data.Bits (xor, (.&.), (.|.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as B64
import Data.Char (isAsciiLower, isDigit)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Read qualified as TR
import Data.Word (Word32)
import System.Directory (createDirectoryIfMissing, doesFileExist, renameFile)
import System.FilePath (takeDirectory)
import System.Posix.Files (fileMode, getFileStatus, setFileMode)

-- * Usernames

newtype Username = Username Text
  deriving stock (Eq, Ord, Show)

usernameText :: Username -> Text
usernameText (Username t) = t

-- | Usernames match @[a-z0-9_-]{1,32}@, so they never contain the @:@ that
-- separates them from the hash in the users file.
parseUsername :: Text -> Maybe Username
parseUsername t
  | T.length t >= 1 && T.length t <= 32 && T.all valid t = Just (Username t)
  | otherwise = Nothing
  where
    valid c = isAsciiLower c || isDigit c || c == '_' || c == '-'

-- | An authenticated user (SPEC §5.2).
newtype User = User {userName :: Username}
  deriving stock (Eq, Show)

-- * Password hashes

data HashParams = HashParams
  { hpMemoryKiB :: Word32
  , hpIterations :: Word32
  , hpParallelism :: Word32
  }
  deriving stock (Eq, Show)

-- | The OWASP minimum for argon2id: 19 MiB, 2 iterations, 1 lane.
defaultHashParams :: HashParams
defaultHashParams = HashParams {hpMemoryKiB = 19456, hpIterations = 2, hpParallelism = 1}

-- | An argon2id hash with the parameters and salt it was made with.
data PasswordHash = PasswordHash
  { phParams :: HashParams
  , phSalt :: ByteString
  , phDigest :: ByteString
  }
  deriving stock (Eq, Show)

hashPassword :: Text -> IO PasswordHash
hashPassword = hashPasswordWith defaultHashParams

hashPasswordWith :: HashParams -> Text -> IO PasswordHash
hashPasswordWith params password = do
  salt <- getRandomBytes 16
  case argon2 params salt password 32 of
    Just digest -> pure (PasswordHash params salt digest)
    Nothing -> ioError (userError ("invalid argon2 parameters: " <> show params))

verifyPassword :: PasswordHash -> Text -> Bool
verifyPassword ph password =
  case argon2 (phParams ph) (phSalt ph) password (BS.length (phDigest ph)) of
    Just digest -> constantTimeEq digest (phDigest ph)
    Nothing -> False

argon2 :: HashParams -> ByteString -> Text -> Int -> Maybe ByteString
argon2 params salt password len =
  case Argon2.hash options (TE.encodeUtf8 password) salt len of
    CryptoPassed digest -> Just digest
    CryptoFailed _ -> Nothing
  where
    options =
      Argon2.Options
        { Argon2.iterations = hpIterations params
        , Argon2.memory = hpMemoryKiB params
        , Argon2.parallelism = hpParallelism params
        , Argon2.variant = Argon2.Argon2id
        , Argon2.version = Argon2.Version13
        }

-- | Compares in time that depends only on the lengths, so a timing attack
-- can't learn how much of a digest matched.
constantTimeEq :: ByteString -> ByteString -> Bool
constantTimeEq a b =
  BS.length a == BS.length b && foldl' (.|.) 0 (BS.zipWith xor a b) == 0

-- | PHC string format:
-- @$argon2id$v=19$m=19456,t=2,p=1$<salt>$<digest>@, with unpadded base64.
renderPasswordHash :: PasswordHash -> Text
renderPasswordHash (PasswordHash params salt digest) =
  T.concat
    [ "$argon2id$v=19$m="
    , showT (hpMemoryKiB params)
    , ",t="
    , showT (hpIterations params)
    , ",p="
    , showT (hpParallelism params)
    , "$"
    , unpaddedBase64 salt
    , "$"
    , unpaddedBase64 digest
    ]
  where
    showT = T.pack . show

-- | Accepts the PHC format 'renderPasswordHash' produces, with parameters in
-- the canonical @m,t,p@ order.
parsePasswordHash :: Text -> Either String PasswordHash
parsePasswordHash t =
  case T.splitOn "$" t of
    ["", "argon2id", "v=19", paramText, saltText, digestText] -> do
      params <- case T.splitOn "," paramText of
        [m, tc, p] ->
          HashParams
            <$> param "m=" m
            <*> param "t=" tc
            <*> param "p=" p
        _ -> Left "expected parameters m=…,t=…,p=…"
      when (hpIterations params < 1 || hpParallelism params < 1 || hpMemoryKiB params < 8 * hpParallelism params) $
        Left "argon2 parameters out of range"
      salt <- decodeBase64 saltText
      digest <- decodeBase64 digestText
      when (BS.length salt < 8) $ Left "salt too short"
      when (BS.length digest < 16) $ Left "digest too short"
      pure (PasswordHash params salt digest)
    _ -> Left "expected an argon2id hash in PHC format ($argon2id$v=19$…)"
  where
    param prefix s = case T.stripPrefix prefix s >>= readWord of
      Just n -> Right n
      Nothing -> Left ("malformed parameter: " <> T.unpack s)
    readWord s = case TR.decimal s of
      Right (n, "") | n <= toInteger (maxBound :: Word32) -> Just (fromInteger n)
      _ -> Nothing

unpaddedBase64 :: ByteString -> Text
unpaddedBase64 = T.dropWhileEnd (== '=') . TE.decodeLatin1 . B64.encode

decodeBase64 :: Text -> Either String ByteString
decodeBase64 s = B64.decode (TE.encodeUtf8 (s <> T.replicate padding "="))
  where
    padding = (4 - T.length s `mod` 4) `mod` 4

-- * Authentication

type Users = Map Username PasswordHash

-- | Checks a username and password against the users. An unknown username
-- still costs one hash verification, so response time doesn't reveal which
-- usernames exist.
authenticate :: Users -> Text -> Text -> Maybe User
authenticate users name password =
  case parseUsername name >>= \u -> (u,) <$> Map.lookup u users of
    Just (u, ph) | verifyPassword ph password -> Just (User u)
    Just _ -> Nothing
    Nothing -> verifyPassword dummyHash password `seq` Nothing

-- | A hash with the default parameters that no password matches in practice.
dummyHash :: PasswordHash
dummyHash = PasswordHash defaultHashParams (BS.replicate 16 0) (BS.replicate 32 0)

-- * The users file

-- | One user per line, @username:hash@. Blank lines and lines starting with
-- @#@ are ignored.
parseUsersFile :: Text -> Either String Users
parseUsersFile contents = foldl' step (Right Map.empty) (zip [1 :: Int ..] (T.lines contents))
  where
    step acc (n, line) = do
      users <- acc
      case userLine line of
        Nothing -> Right users
        Just (name, hashText) -> do
          let at msg = Left ("line " <> show n <> ": " <> msg)
          user <- maybe (at ("invalid username " <> show name)) Right (parseUsername name)
          ph <- either at Right (parsePasswordHash hashText)
          when (Map.member user users) $ at ("duplicate user " <> show name)
          Right (Map.insert user ph users)

-- | Splits a non-comment line into its username and hash.
userLine :: Text -> Maybe (Text, Text)
userLine line
  | T.null stripped || "#" `T.isPrefixOf` stripped = Nothing
  | otherwise = Just (T.drop 1 <$> T.breakOn ":" stripped)
  where
    stripped = T.strip line

-- | Reads the users file, refusing one that group or others can access.
loadUsersFile :: FilePath -> IO (Either String Users)
loadUsersFile path = do
  exists <- doesFileExist path
  if not exists
    then pure (Left ("users file not found: " <> path <> " (create a user with `movie-night add-user <name>`)"))
    else do
      mode <- fileMode <$> getFileStatus path
      if mode .&. 0o077 /= 0
        then pure (Left ("users file " <> path <> " must not be accessible by group or others (run `chmod 600 " <> path <> "`)"))
        else do
          bytes <- BS.readFile path
          pure $ case TE.decodeUtf8' bytes of
            Left _ -> Left ("users file " <> path <> " is not valid UTF-8")
            Right contents -> either (\e -> Left (path <> ": " <> e)) Right (parseUsersFile contents)

-- | Adds a user, creating the file if needed.
addUser :: FilePath -> Username -> PasswordHash -> IO (Either String ())
addUser path user ph = do
  exists <- doesFileExist path
  if not exists
    then Right <$> writeUsersFile path (header <> renderLine user ph)
    else editUsersFile path $ \users contents -> do
      when (Map.member user users) $ Left ("user " <> show (usernameText user) <> " already exists")
      let separator = if T.null contents || "\n" `T.isSuffixOf` contents then "" else "\n"
      Right (contents <> separator <> renderLine user ph)
  where
    header = "# Movie Night users: username:argon2id-hash (see docs/SPEC.md §5.3)\n"

-- | Replaces an existing user's password hash.
setPassword :: FilePath -> Username -> PasswordHash -> IO (Either String ())
setPassword path user ph =
  editUsersFile path $ \users contents -> do
    requireUser user users
    Right (mapUserLines user (const (Just (T.stripEnd (renderLine user ph)))) contents)

-- | Removes a user. Other lines, including comments, are kept as they are.
removeUser :: FilePath -> Username -> IO (Either String ())
removeUser path user =
  editUsersFile path $ \users contents -> do
    requireUser user users
    Right (mapUserLines user (const Nothing) contents)

requireUser :: Username -> Users -> Either String ()
requireUser user users =
  unless (Map.member user users) $ Left ("no such user " <> show (usernameText user))

renderLine :: Username -> PasswordHash -> Text
renderLine user ph = usernameText user <> ":" <> renderPasswordHash ph <> "\n"

-- | Replaces or (with 'Nothing') drops the line for one user.
mapUserLines :: Username -> (Text -> Maybe Text) -> Text -> Text
mapUserLines user f = T.unlines . concatMap go . T.lines
  where
    go line = case userLine line of
      Just (name, _) | name == usernameText user -> maybe [] pure (f line)
      _ -> [line]

-- | Loads and validates the file, applies an edit, and writes the result.
editUsersFile :: FilePath -> (Users -> Text -> Either String Text) -> IO (Either String ())
editUsersFile path edit = do
  loaded <- loadUsersFile path
  case loaded of
    Left err -> pure (Left err)
    Right users -> do
      contents <- TE.decodeUtf8 <$> BS.readFile path
      case edit users contents of
        Left err -> pure (Left err)
        Right new -> Right <$> writeUsersFile path new

-- | Writes the file atomically with mode 0600: the contents go to a
-- temporary file, which is restricted before anything is written to it and
-- then renamed into place.
writeUsersFile :: FilePath -> Text -> IO ()
writeUsersFile path contents = do
  createDirectoryIfMissing True (takeDirectory path)
  let tmp = path <> ".tmp"
  BS.writeFile tmp ""
  setFileMode tmp 0o600
  BS.writeFile tmp (TE.encodeUtf8 contents)
  renameFile tmp path
