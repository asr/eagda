{-# LANGUAGE CPP                  #-}
{-# LANGUAGE FlexibleContexts     #-}
{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE PatternGuards        #-}
{-# LANGUAGE TupleSections        #-}
{-# LANGUAGE TypeSynonymInstances #-}

-- | A syntactic equality check that takes meta instantiations into account,
--   but does not reduce.  It replaces
--   @
--      (v, v') <- instantiateFull (v, v')
--      v == v'
--   @
--   by a more efficient routine which only traverses and instantiates the terms
--   as long as they are equal.

module Agda.TypeChecking.SyntacticEquality (SynEq, checkSyntacticEquality) where

import Prelude hiding (mapM)

import Control.Applicative hiding ((<**>))
import Control.Arrow ((***))
import Control.Monad.State hiding (mapM)

import qualified Agda.Syntax.Common as Common
import Agda.Syntax.Internal

import Agda.TypeChecking.Monad
import Agda.TypeChecking.Reduce (instantiate)
import Agda.TypeChecking.Substitute

import Agda.Utils.Monad (ifM)

#include "undefined.h"
import Agda.Utils.Impossible

-- | Syntactic equality check for terms.
--   @
--      checkSyntacticEquality v v' = do
--        (v,v') <- instantiateFull (v,v')
--         return ((v,v'), v==v')
--   @
--   only that @v,v'@ are only fully instantiated to the depth
--   where they are equal.

{-# SPECIALIZE checkSyntacticEquality :: Term -> Term -> TCM ((Term, Term), Bool) #-}
{-# SPECIALIZE checkSyntacticEquality :: Type -> Type -> TCM ((Type, Type), Bool) #-}
checkSyntacticEquality :: (SynEq a) => a -> a -> TCM ((a, a), Bool)
checkSyntacticEquality v v' = synEq v v' `runStateT` True

-- | Monad for checking syntactic equality
type SynEqM = StateT Bool TCM

-- | Return, flagging inequalty.
inequal :: a -> SynEqM a
inequal a = put False >> return a

-- | If inequality is flagged, return, else continue.
ifEqual :: (a -> SynEqM a) -> (a -> SynEqM a)
ifEqual cont a = ifM get (cont a) (return a)

-- Since List2 is only Applicative, not a monad, I cannot
-- define a List2T monad transformer, so we do it manually:

(<$$>) :: Functor f => (a -> b) -> f (a,a) -> f (b,b)
f <$$> xx = (f *** f) <$> xx

pure2 :: Applicative f => a -> f (a,a)
pure2 a = pure (a,a)

(<**>) :: Applicative f => f (a -> b, a -> b) -> f (a,a) -> f (b,b)
ff <**> xx = pure (uncurry (***)) <*> ff <*> xx

{-
updateSharedM2 :: Monad m =>  (Term -> Term -> m (Term, Term)) -> Term -> Term -> m (Term, Term)
updateSharedM2 f v0@(Shared p) = do
  v <- f (derefPtr p)
  case derefPtr (setPtr v p) of
    Var _ [] -> return v
    _        -> compressPointerChain v0 `pseq` return v0
updateSharedM2 f v = f v

updateSharedTerm2 :: MonadTCM tcm => (Term -> Term -> tcm (Term, Term)) -> Term -> Term -> tcm (Term, Term)
updateSharedTerm f v v' =
  ifM (liftTCM $ asks envAllowDestructiveUpdate)
      (updateSharedM2 f v v')
      (f (ignoreSharing v) (ignoreSharing v'))
-}

-- | Instantiate full as long as things are equal
class SynEq a where
  synEq  :: a -> a -> SynEqM (a,a)
  synEq' :: a -> a -> SynEqM (a,a)
  synEq' a a' = ifEqual (uncurry synEq) (a, a')

-- | Syntactic term equality ignores 'DontCare' stuff.
instance SynEq Term where
  synEq v v' = do
    (v, v') <- lift $ instantiate (v, v')
    -- currently destroys sharing
    -- TODO: preserve sharing!
    case (ignoreSharing v, ignoreSharing v') of
      (Var   i vs, Var   i' vs') | i == i' -> Var i   <$$> synEq vs vs'
      (Con   c vs, Con   c' vs') | c == c' -> Con c   <$$> synEq vs vs'
      (Def   f vs, Def   f' vs') | f == f' -> Def f   <$$> synEq vs vs'
      (MetaV x vs, MetaV x' vs') | x == x' -> MetaV x <$$> synEq vs vs'
      (Lit   l   , Lit   l'    ) | l == l' -> pure2 $ v
      (Lam   h b , Lam   h' b' ) | h == h' -> Lam h   <$$> synEq b b'
      (Level l   , Level l'    )           -> levelTm <$$> synEq l l'
      (Sort  s   , Sort  s'    )           -> sortTm  <$$> synEq s s'
      (Pi    a b , Pi    a' b' )           -> Pi      <$$> synEq a a' <**> synEq' b b'
      (DontCare _, DontCare _  )           -> pure (v, v')
         -- Irrelevant things are syntactically equal. ALT:
         -- DontCare <$$> synEq v v'
      (Shared{}  , _           )           -> __IMPOSSIBLE__
      (_         , Shared{}    )           -> __IMPOSSIBLE__
      _                                    -> inequal (v, v')

instance SynEq Level where
  synEq (Max vs) (Max vs') = levelMax <$$> synEq vs vs'

instance SynEq PlusLevel where
  synEq l l' = do
    case (l, l') of
      (ClosedLevel v, ClosedLevel v') | v == v' -> pure2 l
      (Plus n v,      Plus n' v')     | n == n' -> Plus n <$$> synEq v v'
      _ -> inequal (l, l')

instance SynEq LevelAtom where
  synEq l l' = do
    l  <- lift (unBlock =<< instantiate l)
    case (l, l') of
      (MetaLevel m vs  , MetaLevel m' vs'  ) | m == m' -> MetaLevel m    <$$> synEq vs vs'
      (UnreducedLevel v, UnreducedLevel v' )           -> UnreducedLevel <$$> synEq v v'
      -- The reason for being blocked should not matter for equality.
      (NeutralLevel r v, NeutralLevel r' v')           -> NeutralLevel r <$$> synEq v v'
      (BlockedLevel m v, BlockedLevel m' v')           -> BlockedLevel m <$$> synEq v v'
      _ -> inequal (l, l')
    where
      unBlock l =
        case l of
          BlockedLevel m v ->
            ifM (isInstantiatedMeta m)
                (pure $ UnreducedLevel v)
                (pure l)
          _ -> pure l

instance SynEq Sort where
  synEq s s' = do
    (s, s') <- lift $ instantiate (s, s')
    case (s, s') of
      (Type l  , Type l'   ) -> levelSort <$$> synEq l l'
      (DLub a b, DLub a' b') -> dLub <$$> synEq a a' <**> synEq' b b'
      (Prop    , Prop      ) -> pure2 s
      (Inf     , Inf       ) -> pure2 s
      _ -> inequal (s, s')

-- | Syntactic equality ignores sorts.
instance SynEq Type where
  synEq (El s t) (El s' t') = (El s *** El s') <$> synEq t t'

instance SynEq a => SynEq [a] where
  synEq as as'
    | length as == length as' = unzip <$> zipWithM synEq' as as'
    | otherwise               = inequal (as, as')

instance SynEq a => SynEq (Elim' a) where
  synEq e e' =
    case (e, e') of
      (Proj f , Proj f' ) | f == f' -> pure2 e
      (Apply a, Apply a') -> Apply <$$> synEq a a'
      _                   -> inequal (e, e')

instance (Subst a, SynEq a) => SynEq (Abs a) where
  synEq a a' =
    case (a, a') of
      (NoAbs x b, NoAbs x' b') -> (NoAbs x *** NoAbs x') <$>  synEq b b'
      (Abs   x b, Abs   x' b') -> (Abs x *** Abs x') <$> synEq b b'
      (Abs   x b, NoAbs x' b') -> Abs x  <$$> synEq b (raise 1 b')  -- TODO: mkAbs?
      (NoAbs x b, Abs   x' b') -> Abs x' <$$> synEq (raise 1 b) b'

{- TRIGGERS test/fail/UnequalHiding
-- | Ignores 'ArgInfo'.
instance SynEq a => SynEq (Common.Arg c a) where
  synEq (Common.Arg ai a) (Common.Arg ai' a') = (Common.Arg ai *** Common.Arg ai') <$> synEq a a'

-- | Ignores 'ArgInfo'.
instance SynEq a => SynEq (Common.Dom c a) where
  synEq (Common.Dom ai a) (Common.Dom ai' a') = (Common.Dom ai *** Common.Dom ai') <$> synEq a a'
-}

instance (SynEq a, SynEq c) => SynEq (Common.Arg c a) where
  synEq (Common.Arg ai a) (Common.Arg ai' a') = Common.Arg <$$> synEq ai ai' <**> synEq a a'

instance (SynEq a, SynEq c) => SynEq (Common.Dom c a) where
  synEq (Common.Dom ai a) (Common.Dom ai' a') = Common.Dom <$$> synEq ai ai' <**> synEq a a'

instance (SynEq c) => SynEq (Common.ArgInfo c) where
  synEq ai@(Common.ArgInfo h r c) ai'@(Common.ArgInfo h' r' c')
    | h == h', r == r' = Common.ArgInfo h r <$$> synEq c c'
    | otherwise        = inequal (ai, ai')
