-- The ATP pragmas must to have at least an argument

-- This error is detected by Agda.TypeChecking.Rules.Decl.

module ATPMissingArgument where

{-# ATP axiom #-}
