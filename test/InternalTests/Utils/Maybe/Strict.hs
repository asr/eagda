{-# LANGUAGE CPP             #-}
{-# LANGUAGE TemplateHaskell #-}

module InternalTests.Utils.Maybe.Strict ( tests ) where

import Agda.Utils.Maybe.Strict

#if __GLASGOW_HASKELL__ <= 708
import Control.Applicative ( (<$>) )
#endif

import Data.Semigroup ()

import Prelude hiding ( Maybe )

import InternalTests.Helpers

------------------------------------------------------------------------------
-- Instances

instance Arbitrary a => Arbitrary (Maybe a) where
  arbitrary = toStrict <$> arbitrary
  shrink    = map toStrict . shrink . toLazy

instance CoArbitrary a => CoArbitrary (Maybe a) where
  coarbitrary = coarbitrary . toLazy

------------------------------------------------------------------------------
-- Properties

-- | 'Maybe a' is a monoid.
prop_monoid_Maybe :: Property3 (Maybe ())
prop_monoid_Maybe = isMonoid

------------------------------------------------------------------------
-- Hack to make $quickCheckAll work under ghc-7.8
return []

-- All tests
tests :: IO Bool
tests = do
  putStrLn "InternalTests.Utils.Maybe.Strict"
  $quickCheckAll
