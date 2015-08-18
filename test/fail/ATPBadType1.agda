-- An ATP type must be used with data-types or postulates.

-- This error is detected by Syntax.Translation.ConcreteToAbstract.

module ATPBadType1 where

data Bool : Set where
  false true : Bool

{-# ATP type false #-}
