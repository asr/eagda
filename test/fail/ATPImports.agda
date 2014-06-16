-- The ATP pragma must appear in the same module where its argument is
-- defined.

module ATPImports where

open import Imports.ATP-A

{-# ATP axiom p #-}

postulate foo : a ≡ b
{-# ATP prove foo #-}
