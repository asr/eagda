-- An ATP conjecture must be used with postulates.

-- This error is detected by Syntax.Translation.ConcreteToAbstract.

module ATPBadConjecture1 where

data Bool : Set where
  false true : Bool

{-# ATP prove false #-}
