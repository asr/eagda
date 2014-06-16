module ATPRepeteadConjecture where

module Bug where

postulate
  D   : Set
  _≡_ : D → D → Set
  p   : ∀ d e → d ≡ e

-- The conjecture foo is rejected because is is repetead.
postulate foo : ∀ d e → d ≡ e
{-# ATP prove foo #-}
{-# ATP prove foo p #-}
