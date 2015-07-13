-- An ATP conjecture cannot have duplicate local hints.

-- This error is detected by Syntax.Translation.ConcreteToAbstract.

module ATPBadLocalHint2 where

postulate
  D   : Set
  foo : D
  bar : D

{-# ATP prove foo bar bar #-}
