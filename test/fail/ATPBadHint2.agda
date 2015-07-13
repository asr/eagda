-- An ATP hint must be used with functions.

-- This error is detected by TypeChecking.Rules.Decl.

module ATPBadHint2 where

data Bool : Set where
  false true : Bool

{-# ATP hint Bool #-}
