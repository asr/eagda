-- The ATP pragma with the role <definition> must be used with functions.

-- This error is detected by Agda.TypeChecking.Rules.Decl.

module ATPBadDefinition2 where

postulate
  D    : Set
  zero : D
  succ : D → D

data N : D → Set where
  zN :               N zero
  sN : ∀ {n} → N n → N (succ n)
{-# ATP definition zN #-}
