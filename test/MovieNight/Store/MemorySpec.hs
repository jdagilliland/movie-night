module MovieNight.Store.MemorySpec (spec) where

import MovieNight.Store.Memory (newMemoryStore)
import MovieNight.StoreContract (storeContract)
import Test.Hspec

spec :: Spec
spec = storeContract (newMemoryStore >>=)
