-- An ATP conjecture must be used with postulates.

-- This error is detected by TypeChecking.Rules.Decl.

module ATPBadConjecture2 where

data Bool : Set where
  false true : Bool

{-# ATP prove Bool #-}
