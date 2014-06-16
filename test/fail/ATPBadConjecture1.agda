-- The ATP pragma with the role <prove> must be used with postulates.

-- This error is detected by Agda.Syntax.Translation.ConcreteToAbstract.

module ATPBadConjecture1 where

postulate
  D    : Set
  zero : D
  succ : D → D

data N : D → Set where
  zN :               N zero
  sN : ∀ {n} → N n → N (succ n)
{-# ATP prove zN #-}
