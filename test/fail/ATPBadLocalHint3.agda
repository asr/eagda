-- An ATP local hint can be only a postulate, function or a data
-- constructor.

-- This error is detected by Syntax.Translation.ConcreteToAbstract.

module ATPBadLocalHint3 where

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
