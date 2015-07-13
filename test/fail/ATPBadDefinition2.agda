-- An ATP definition must be used with functions.

-- This error is detected by TypeChecking.Rules.Decl.

module ATPBadDefinition2 where

data Bool : Set where
  false true : Bool

{-# ATP definition Bool #-}
