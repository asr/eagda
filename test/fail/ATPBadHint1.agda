-- An ATP hint must be used with functions.

-- This error is detected by Syntax.Translation.ConcreteToAbstract.

module ATPBadHint1 where

data Bool : Set where
  false true : Bool

{-# ATP hint false #-}
