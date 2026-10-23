-- | Short, random, unguessable paste identifiers (SPEC §4.2).
module MovieNight.PasteId
  ( PasteId
  , pasteIdText
  , parsePasteId
  , generatePasteId
  , pasteIdLength
  , base62Alphabet
  , byteToBase62
  ) where

import Crypto.Random (getRandomBytes)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word8)
import Web.HttpApiData (FromHttpApiData (..), ToHttpApiData (..))

-- | Only 'parsePasteId' and 'generatePasteId' make these. The accessor is a
-- separate function, not a record field: record update syntax needs only the
-- field in scope, so an exported field would let any module build an invalid
-- 'PasteId'.
newtype PasteId = PasteId Text
  deriving stock (Eq, Ord, Show)

pasteIdText :: PasteId -> Text
pasteIdText (PasteId t) = t

-- | FR-8: IDs are 8 characters long.
pasteIdLength :: Int
pasteIdLength = 8

-- | FR-8: @[0-9A-Za-z]@.
base62Alphabet :: [Char]
base62Alphabet = ['0' .. '9'] <> ['A' .. 'Z'] <> ['a' .. 'z']

-- | Accepts exactly the strings 'generatePasteId' can produce.
parsePasteId :: Text -> Maybe PasteId
parsePasteId t
  | T.length t == pasteIdLength && T.all (`elem` base62Alphabet) t = Just (PasteId t)
  | otherwise = Nothing

-- | Malformed IDs in a URL are rejected before reaching a handler (→ 400).
instance FromHttpApiData PasteId where
  parseUrlPiece t = maybe (Left "malformed paste id") Right (parsePasteId t)

instance ToHttpApiData PasteId where
  toUrlPiece = pasteIdText

-- | Maps a random byte to a base62 character by rejection sampling.
--
-- 256 is not a multiple of 62, so a plain @mod 62@ would favour the first
-- characters of the alphabet. Bytes below 248 (= 4 × 62) map uniformly;
-- the remaining 8 values are rejected.
byteToBase62 :: Word8 -> Maybe Char
byteToBase62 b
  | b < 248 = Just (base62Alphabet !! (fromIntegral b `mod` 62))
  | otherwise = Nothing

-- | FR-9: generates an ID from a cryptographically secure RNG.
generatePasteId :: IO PasteId
generatePasteId = PasteId . T.pack <$> go pasteIdLength
  where
    -- About 3% of bytes are rejected, so one extra batch is rarely needed.
    go :: Int -> IO [Char]
    go 0 = pure []
    go n = do
      bytes <- getRandomBytes (2 * n) :: IO ByteString
      let accepted = take n (BS.foldr (\b cs -> maybe cs (: cs) (byteToBase62 b)) [] bytes)
      (accepted <>) <$> go (n - length accepted)
