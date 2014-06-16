-- The ATP pragma with the role <prove> must be used with postulates.

-- This error is detected by Agda.TypeChecking.Rules.Decl.

module ATPBadConjecture2 where

postulate
  D : Set

data _≡_ (x : D) : D → Set where
  refl : x ≡ x

sym : ∀ {m n} → m ≡ n → n ≡ m
sym refl = refl
{-# ATP prove sym #-}
