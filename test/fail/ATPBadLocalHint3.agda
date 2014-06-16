-- A conjecture cannot have duplicate local hints.

-- This error is detected by Agda.Syntax.Translation.ConcreteToAbstract.

module ATPBadLocalHint3 where

postulate
  D : Set
  foo : D
  bar : D
{-# ATP prove foo bar bar #-}
