-- A local hint cannot be equal to the conjecture in which it is used.

-- This error is detected by Agda.Syntax.Translation.ConcreteToAbstract.

module ATPBadLocalHint2 where

postulate
  D : Set
  p : D
{-# ATP prove p p #-}
