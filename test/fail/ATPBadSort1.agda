-- An ATP sort must be used with data-types.

-- This error is detected by Syntax.Translation.ConcreteToAbstract.

module ATPBadSort1 where

data Bool : Set where
  false true : Bool

{-# ATP sort false #-}
