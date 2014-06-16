-- The ATP pragma with the role <axiom> must be used with postulates or
-- data constructors.

-- This error is detected by Agda.TypeChecking.Rules.Decl.

module ATPBadAxiom where

foo : Set → Set
foo A = A
{-# ATP axiom foo #-}
