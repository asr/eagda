
module Agda.TypeChecking.Rules.Term where

import Agda.Syntax.Common (WithHiding, Arg)
import qualified Agda.Syntax.Abstract as A
import Agda.Syntax.Internal
import Agda.TypeChecking.Monad.Base

isType_ :: A.Expr -> TCM Type

checkExpr :: A.Expr -> Type -> TCM Term
inferExpr :: A.Expr -> TCM (Term, Type)

checkPostponedLambda :: Arg ([WithHiding Name], Maybe Type) -> A.Expr -> Type -> TCM Term

unquoteTactic :: Term -> Term -> Type -> TCM Term -> TCM Term
