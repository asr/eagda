module Agda.TypeChecking.MetaVars where

import Agda.Syntax.Common           ( Arg, Dom )
import Agda.Syntax.Internal         ( MetaId, Term, Type, Args, Abs, Telescope )
import Agda.Syntax.Internal.Generic ( TermLike )
import Agda.TypeChecking.Monad.Base ( TCM, RunMetaOccursCheck(..), CompareDirection(..), Candidate )

type Condition = Dom Type -> Abs Type -> Bool
newArgsMeta'      :: Condition -> Type -> TCM Args
newArgsMeta       :: Type -> TCM Args
assignTerm        :: MetaId -> [Arg String] -> Term -> TCM ()
etaExpandMetaSafe :: MetaId -> TCM ()
assignV           :: CompareDirection -> MetaId -> Args -> Term -> TCM ()
assign            :: CompareDirection -> MetaId -> Args -> Term -> TCM ()
newIFSMeta        :: String -> Type -> Maybe [Candidate] -> TCM Term
newValueMeta      :: RunMetaOccursCheck -> Type -> TCM Term
newNamedValueMeta :: RunMetaOccursCheck -> String -> Type -> TCM Term
newTelMeta        :: Telescope -> TCM Args
allMetas          :: TermLike a => a -> [MetaId]
