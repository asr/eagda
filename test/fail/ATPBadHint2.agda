-- The ATP pragma with the role <hint> must be used with functions.

-- This error is detected by Agda.TypeChecking.Rules.Decl.

module ATPBadHint2 where

data _∨_ (A B : Set) : Set where
  inj₁ : A → A ∨ B
  inj₂ : B → A ∨ B

postulate
  ∨-comm : {A B : Set} → A ∨ B → B ∨ A
{-# ATP hint ∨-comm #-}
