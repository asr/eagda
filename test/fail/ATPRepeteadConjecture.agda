module ATPRepeteadConjecture where

-- This error is detected by TypeChecking.Monad.Signature.

postulate
  D   : Set
  _≡_ : D → D → Set
  p   : ∀ d e → d ≡ e

-- The conjecture foo is rejected because it is repetead.
postulate foo : ∀ d e → d ≡ e
{-# ATP prove foo #-}
{-# ATP prove foo p #-}
