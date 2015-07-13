-- An ATP definition must be used with functions.

-- This error is detected by Syntax.Translation.ConcreteToAbstract.

module ATPBadDefinition1 where

data Bool : Set where
  false true : Bool

{-# ATP definition false #-}
