
module _ where

open import Common.Prelude hiding (_>>=_)
open import Common.Reflection

pattern `Nat = def (quote Nat) []

unquoteDecl f =
  declareDef (vArg f) `Nat
