open import Common.Prelude
open import Common.Level
open import Common.Reflection
open import Common.Equality

test₁ : quoteTerm lzero ≡ def (quote lzero) []
test₁ = refl

foo : (l : Level) → Bool → Bool
foo _ false = true
foo _ true = false

test₂ : quoteTerm (foo lzero) ≡ def (quote foo) (arg (arginfo visible relevant) (def (quote lzero) []) ∷ [])
test₂ = refl

test₃ : unquote (quoteTerm lzero) ≡ lzero
test₃ = refl
