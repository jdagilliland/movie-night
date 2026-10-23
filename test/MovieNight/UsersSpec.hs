module MovieNight.UsersSpec
  ( spec
  , cheapParams
  ) where

import Data.Bits ((.&.))
import Data.Either (isLeft)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromJust, isJust)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import MovieNight.Users
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (fileMode, getFileStatus, setFileMode)
import Test.Hspec

-- | Fast parameters for tests; real hashes use 'defaultHashParams'.
cheapParams :: HashParams
cheapParams = HashParams {hpMemoryKiB = 8, hpIterations = 1, hpParallelism = 1}

alice, bob :: Username
alice = fromJust (parseUsername "alice")
bob = fromJust (parseUsername "bob")

withUsersPath :: (FilePath -> IO a) -> IO a
withUsersPath action = withSystemTempDirectory "movie-night" $ \dir -> action (dir </> "data" </> "users")

modeOf :: FilePath -> IO Int
modeOf path = fromIntegral . (.&. 0o777) . fileMode <$> getFileStatus path

spec :: Spec
spec = do
  describe "§5.3: parseUsername" $ do
    it "accepts lowercase letters, digits, _ and -" $
      fmap usernameText (parseUsername "a_b-9") `shouldBe` Just "a_b-9"

    it "rejects empty, over-long, uppercase, and colon-containing names" $
      mapM_
        (\n -> parseUsername n `shouldBe` Nothing)
        ["", T.replicate 33 "a", "Alice", "a:b", "a b"]

    it "accepts a 32-character name" $
      parseUsername (T.replicate 32 "a") `shouldSatisfy` isJust

  describe "§5.3: password hashes" $ do
    it "verify the password they were made from, and no other" $ do
      ph <- hashPasswordWith cheapParams "correct horse"
      verifyPassword ph "correct horse" `shouldBe` True
      verifyPassword ph "wrong horse" `shouldBe` False

    it "use a fresh salt each time" $ do
      a <- hashPasswordWith cheapParams "same"
      b <- hashPasswordWith cheapParams "same"
      renderPasswordHash a `shouldNotBe` renderPasswordHash b

    it "round-trip through the PHC format" $ do
      ph <- hashPasswordWith cheapParams "pw"
      parsePasswordHash (renderPasswordHash ph) `shouldBe` Right ph

    it "render the default parameters as in the spec" $ do
      ph <- hashPassword "pw"
      renderPasswordHash ph `shouldSatisfy` T.isPrefixOf "$argon2id$v=19$m=19456,t=2,p=1$"

    it "reject other formats and out-of-range parameters" $
      mapM_
        (\h -> parsePasswordHash h `shouldSatisfy` isLeft)
        [ "plaintext"
        , "$argon2i$v=19$m=19456,t=2,p=1$c2FsdHNhbHQ$aGFzaGhhc2hoYXNoaGFzaA"
        , "$argon2id$v=19$t=2,m=19456,p=1$c2FsdHNhbHQ$aGFzaGhhc2hoYXNoaGFzaA"
        , "$argon2id$v=19$m=4,t=2,p=1$c2FsdHNhbHQ$aGFzaGhhc2hoYXNoaGFzaA"
        , "$argon2id$v=19$m=19456,t=0,p=1$c2FsdHNhbHQ$aGFzaGhhc2hoYXNoaGFzaA"
        ]

  describe "authenticate" $ do
    it "returns the user for correct credentials" $ do
      ph <- hashPasswordWith cheapParams "pw"
      authenticate (Map.singleton alice ph) "alice" "pw" `shouldBe` Just (User alice)

    it "rejects a wrong password, an unknown user, and an invalid name" $ do
      ph <- hashPasswordWith cheapParams "pw"
      let users = Map.singleton alice ph
      authenticate users "alice" "nope" `shouldBe` Nothing
      authenticate users "bob" "pw" `shouldBe` Nothing
      authenticate users "Alice:" "pw" `shouldBe` Nothing

  describe "§5.3: parseUsersFile" $ do
    it "ignores comments and blank lines" $ do
      ph <- hashPasswordWith cheapParams "pw"
      let contents = T.unlines ["# users", "", "  # indented comment", "alice:" <> renderPasswordHash ph]
      parseUsersFile contents `shouldBe` Right (Map.singleton alice ph)

    it "reports the line number of a malformed line" $ do
      ph <- hashPasswordWith cheapParams "pw"
      let contents = T.unlines ["# users", "alice:" <> renderPasswordHash ph, "bob:not-a-hash"]
      parseUsersFile contents `shouldSatisfy` either ("line 3:" `T.isPrefixOf`) (const False) . mapLeft T.pack

    it "rejects invalid usernames and duplicates" $ do
      ph <- renderPasswordHash <$> hashPasswordWith cheapParams "pw"
      parseUsersFile ("Alice:" <> ph) `shouldSatisfy` isLeft
      parseUsersFile (T.unlines ["alice:" <> ph, "alice:" <> ph]) `shouldSatisfy` isLeft

  describe "§5.3: loadUsersFile" $ do
    it "rejects a missing file, pointing at add-user" $
      withUsersPath $ \path -> do
        result <- loadUsersFile path
        result `shouldSatisfy` either (T.isInfixOf "add-user" . T.pack) (const False)

    it "refuses a file readable by group or others" $
      withUsersPath $ \path -> do
        ph <- hashPasswordWith cheapParams "pw"
        _ <- addUser path alice ph
        setFileMode path 0o644
        loadUsersFile path >>= (`shouldSatisfy` isLeft)

  describe "§6: add-user, set-password, remove-user" $ do
    it "add-user creates the file with mode 0600" $
      withUsersPath $ \path -> do
        ph <- hashPasswordWith cheapParams "pw"
        addUser path alice ph `shouldReturn` Right ()
        modeOf path `shouldReturn` 0o600
        loadUsersFile path `shouldReturn` Right (Map.singleton alice ph)

    it "add-user appends further users and refuses an existing one" $
      withUsersPath $ \path -> do
        a <- hashPasswordWith cheapParams "a"
        b <- hashPasswordWith cheapParams "b"
        _ <- addUser path alice a
        addUser path bob b `shouldReturn` Right ()
        addUser path alice b >>= (`shouldSatisfy` isLeft)
        loadUsersFile path `shouldReturn` Right (Map.fromList [(alice, a), (bob, b)])

    it "set-password replaces only that user's hash" $
      withUsersPath $ \path -> do
        a <- hashPasswordWith cheapParams "a"
        b <- hashPasswordWith cheapParams "b"
        a' <- hashPasswordWith cheapParams "a2"
        _ <- addUser path alice a
        _ <- addUser path bob b
        setPassword path alice a' `shouldReturn` Right ()
        loadUsersFile path `shouldReturn` Right (Map.fromList [(alice, a'), (bob, b)])
        modeOf path `shouldReturn` 0o600

    it "remove-user drops the user and keeps comments" $
      withUsersPath $ \path -> do
        a <- hashPasswordWith cheapParams "a"
        b <- hashPasswordWith cheapParams "b"
        _ <- addUser path alice a
        _ <- addUser path bob b
        removeUser path alice `shouldReturn` Right ()
        loadUsersFile path `shouldReturn` Right (Map.singleton bob b)
        TIO.readFile path >>= (`shouldSatisfy` T.isPrefixOf "# Movie Night users")

    it "set-password and remove-user refuse an unknown user" $
      withUsersPath $ \path -> do
        a <- hashPasswordWith cheapParams "a"
        _ <- addUser path alice a
        setPassword path bob a >>= (`shouldSatisfy` isLeft)
        removeUser path bob >>= (`shouldSatisfy` isLeft)

mapLeft :: (a -> b) -> Either a c -> Either b c
mapLeft f = either (Left . f) Right
