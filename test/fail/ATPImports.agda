-- An ATP-pragma must appear in the same module where its argument is
-- defined.

-- This error is detected by TypeChecking.Monad.Signature.

module ATPImports where

open import Imports.ATP-A

{-# ATP axiom p #-}

postulate foo : a ≡ b
{-# ATP prove foo #-}
