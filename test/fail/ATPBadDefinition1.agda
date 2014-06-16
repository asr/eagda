-- The ATP pragma with the role <defintion> must be used with functions.

-- This error is detected by Agda.Syntax.Translation.ConcreteToAbstract.

module ATPBadDefinition1 where

postulate
  D    : Set
  zero : D
  succ : D → D

data N : D → Set where
  zN :               N zero
  sN : ∀ {n} → N n → N (succ n)
{-# ATP definition zN #-}
