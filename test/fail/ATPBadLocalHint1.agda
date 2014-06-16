-- In an ATP pragma only postulates, functions or data constructors
-- can be used as <local hints>.

-- This error is detected by Agda.Syntax.Translation.ConcreteToAbstract.

module ATPBadLocalHint1 where

postulate
  D    : Set
  _≡_  : D → D → Set
  zero : D
  succ : D → D

data N : D → Set where
  zN :               N zero
  sN : ∀ {n} → N n → N (succ n)

refl : ∀ n → N n → n ≡ n
refl n Nn = prf
  where
    postulate prf : n ≡ n
    {-# ATP prove prf Nn #-}
