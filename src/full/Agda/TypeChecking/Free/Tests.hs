{-# OPTIONS_GHC -fno-warn-missing-signatures #-}

{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}

#if __GLASGOW_HASKELL__ >= 710
{-# LANGUAGE FlexibleContexts #-}
#endif

-- | Tests for free variable computations.

module Agda.TypeChecking.Free.Tests (tests) where

import Control.Applicative ((<*>))

import Data.Functor
import Data.List as List
import Data.Maybe
import Data.Monoid

import Test.QuickCheck
import Test.QuickCheck.All

import Agda.Syntax.Common
import Agda.Syntax.Internal

import Agda.TypeChecking.Free.Lazy hiding (FlexRig(..))
import Agda.TypeChecking.Free.Lazy (FlexRig)
import qualified Agda.TypeChecking.Free.Lazy as Free

import qualified Agda.TypeChecking.Free.Old as Old

import Agda.TypeChecking.Free (freeIn)
import qualified Agda.TypeChecking.Free as New

import Agda.TypeChecking.Test.Generators
import Agda.Utils.TestHelpers

-- Generators

instance Arbitrary FlexRig where
  arbitrary = arbitraryBoundedEnum

instance Arbitrary VarOcc where
  arbitrary = VarOcc <$> arbitrary <*> arbitrary

-- * Properties of 'FlexRig'

-- | Ensure the correct linear order is derived.

prop_FlexRig_min = minBound == Free.Flexible

prop_FlexRig_order = strictlyAscending
  [ Free.Flexible, Free.WeaklyRigid, Free.Unguarded, Free.StronglyRigid ]

strictlyAscending l = and $ zipWith (<) l $ tail l

-- ** 'composeFlexRig' forms an idempotent commutative monoid with
-- unit 'Unguarded' and zero 'Flexible'

prop_composeFlexRig_associative = associative composeFlexRig
prop_composeFlexRig_commutative = commutative composeFlexRig
prop_composeFlexRig_idempotent  = idempotent  composeFlexRig
prop_composeFlexRig_zero = isZero   Free.Flexible  composeFlexRig
prop_composeFlexRig_unit = identity Free.Unguarded composeFlexRig

prop_FlexRig_distributive = distributive composeFlexRig max

-- Not true (I did not expect it to be true, just for sanity I checked):
-- prop_FlexRig_distributive' = distributive max composeFlexRig

-- ** 'maxVarOcc'

prop_maxVarOcc_top = isZero   topVarOcc maxVarOcc
prop_maxVarOcc_bot = identity botVarOcc maxVarOcc

-- * Unit tests

prop_freeIn = all (0 `freeIn`)
  [ var 0
  , Lam defaultArgInfo $ Abs "x" $ var 1
  , Sort $ varSort 0
  ]

-- * Conformance with old implementation

prop_old_freeVars_Pi = same_freeVars ty

same_freeVars t = new_to_old_FV (New.freeVars t) == Old.freeVars t

old_to_new_FV (Old.FV a b c d e f) = New.FV a b c d e f
new_to_old_FV (New.FV a b c d e f) = Old.FV a b c d e f

ty = Pi (defaultDom ab) $ Abs "x" $ El (Type $ Max []) $ var 5
  where
    a  = El Prop $
           var 4
    b  = El (Type $ Max []) $
           Sort $ Type $ Max []
    ab = El (Type $ Max [ClosedLevel 1]) $
           Pi (defaultDom a) (Abs "x" b)

new_fv_ty :: New.FreeVars
new_fv_ty = New.freeVars ty

old_fv_ty :: Old.FreeVars
old_fv_ty = Old.freeVars ty


prop_old_freeVars_Term conf x = forAll (genC conf) $ \ (t :: Term) ->
   same_freeVars t

prop_old_freeIn_Term conf x = forAll (genC conf) $ \ (t :: Term) ->
   New.freeIn x t == Old.freeIn x t
prop_old_freeIn_Type conf x = forAll (genC conf) $ \ (t :: Type) ->
   New.freeIn x t == Old.freeIn x t


-- Template Haskell hack to make the following $quickCheckAll work
-- under ghc-7.8.
return [] -- KEEP!

-- | All tests as collected by 'quickCheckAll'.
tests :: IO Bool
tests = do
  putStrLn "Agda.TypeChecking.Free.Tests"
  $quickCheckAll
