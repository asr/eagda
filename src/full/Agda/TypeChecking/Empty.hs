
module Agda.TypeChecking.Empty where

import Control.Applicative
import Control.Monad

import Agda.Syntax.Common
import Agda.Syntax.Internal
import Agda.Syntax.Position

import Agda.TypeChecking.Monad
import Agda.TypeChecking.Coverage
import Agda.TypeChecking.Constraints
import Agda.TypeChecking.Reduce
import Agda.TypeChecking.Substitute

-- | Check whether a type is empty.
--   This check may be postponed as emptiness constraint.

isEmptyType :: Range -> Type -> TCM ()
isEmptyType r t = do
  let postpone t = addConstraint $ IsEmpty r t
  -- If t is blocked or a meta, we cannot decide emptiness now.  Postpone.
  ifBlockedType t (\ _ t -> postpone t) $ {- else -} \ t -> do
    -- from the current context xs:ts, create a pattern list
    -- xs _ : ts t and try to split on _ (the last variable)
    tel0 <- getContextTelescope
    let gamma = telToList tel0 ++ [domFromArg $ defaultArg (underscore, t)]
        ps    = [ Arg info $ namedVarP x | Dom info (x, _) <- gamma ]
        tel   = telFromList gamma

    dontAssignMetas $ do
      r <- splitLast Inductive tel ps
      case r of
        Left (CantSplit c tel us vs) -> postpone t
        Left _                       -> typeError $ ShouldBeEmpty t []
        Right cov -> do
          let cs = splitClauses cov
          unless (null cs) $
            typeError $ ShouldBeEmpty t $ map (namedArg . last . scPats) $ cs
