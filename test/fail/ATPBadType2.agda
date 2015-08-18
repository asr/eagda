-- An ATP type must be used with data-types or postulates.

-- This error is detected by TypeChecking.Rules.Decl.

module ATPBadType2 where

foo : Set → Set
foo A = A

{-# ATP type foo #-}
