-- An ATP local hint cannot be equal to the conjecture in which it is
-- used.

-- This error is detected by Syntax.Translation.ConcreteToAbstract.

module ATPBadLocalHint1 where

postulate
  D : Set
  p : D

{-# ATP prove p p #-}
