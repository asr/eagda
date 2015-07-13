-- An ATP sort must be used with data-types.

-- This error is detected by TypeChecking.Rules.Decl.

module ATPBadSort2 where

foo : Set → Set
foo A = A

{-# ATP sort foo #-}
