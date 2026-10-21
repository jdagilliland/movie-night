module MovieNight
  ( appName
  ) where

import Data.String (IsString)

appName :: IsString s => s
appName = "movie-night"
