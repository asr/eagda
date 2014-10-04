{-# LANGUAGE CPP              #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TupleSections    #-}

module Agda.TypeChecking.Reduce.Monad
  ( constructorForm
  , enterClosure
  , underAbstraction_
  , getConstInfo
  , isInstantiatedMeta
  , lookupMeta
  , reportSDoc, reportSLn
  , traceSLn, traceSDoc
  ) where

import Control.Arrow ((***), first, second)
import Control.Applicative
import Control.Monad.Reader
import Control.Monad.Identity

import qualified Data.Map as Map
import Data.Maybe

import Debug.Trace
import System.IO.Unsafe

import Agda.Syntax.Common (unDom)
import Agda.Syntax.Position
import Agda.Syntax.Internal
import Agda.TypeChecking.Monad hiding
  ( enterClosure, underAbstraction_, underAbstraction, addCtx, mkContextEntry,
    isInstantiatedMeta, verboseS, reportSDoc, reportSLn, typeOfConst, lookupMeta, instantiateDef )
import Agda.TypeChecking.Monad.Builtin hiding ( constructorForm )
import Agda.TypeChecking.Substitute
import Agda.Interaction.Options

import Agda.Utils.Fresh
import qualified Agda.Utils.HashMap as HMap
import Agda.Utils.Monad
import Agda.Utils.Pretty

#include "../../undefined.h"
import Agda.Utils.Impossible

gets :: (TCState -> a) -> ReduceM a
gets f = f . redSt <$> ReduceM ask

askR :: ReduceM ReduceEnv
askR = ReduceM ask

localR :: (ReduceEnv -> ReduceEnv) -> ReduceM a -> ReduceM a
localR f = ReduceM . local f . unReduceM

instance HasOptions ReduceM where
  pragmaOptions      = gets stPragmaOptions
  commandLineOptions = do
    p  <- gets stPragmaOptions
    cl <- gets $ stPersistentOptions . stPersistent
    return $ cl{ optPragmaOptions = p }

instance HasBuiltins ReduceM where
  getBuiltinThing b = liftM2 mplus (Map.lookup b <$> gets stLocalBuiltins)
                                   (Map.lookup b <$> gets stImportedBuiltins)

constructorForm :: Term -> ReduceM Term
constructorForm v = do
  mz <- getBuiltin' builtinZero
  ms <- getBuiltin' builtinSuc
  return $ fromMaybe v $ constructorForm' mz ms v

enterClosure :: Closure a -> (a -> ReduceM b) -> ReduceM b
enterClosure (Closure sig env scope x) f = localR (mapRedEnvSt inEnv inState) (f x)
  where
    inEnv   e = env { envAllowDestructiveUpdate = envAllowDestructiveUpdate e }
    inState s = s { stScope = scope }   -- TODO: use the signature here? would that fix parts of issue 118?

withFreshR :: HasFresh i FreshThings => (i -> ReduceM a) -> ReduceM a
withFreshR f = do
  s <- gets id
  let (i, s') = nextFresh s
  localR (mapRedSt $ const s') (f i)

withFreshName :: Range -> ArgName -> (Name -> ReduceM a) -> ReduceM a
withFreshName r s k = withFreshR $ \i -> k (mkName r i s)

withFreshName_ :: ArgName -> (Name -> ReduceM a) -> ReduceM a
withFreshName_ = withFreshName noRange

mkContextEntry :: Dom (Name, Type) -> (ContextEntry -> ReduceM a) -> ReduceM a
mkContextEntry x k = withFreshR $ \i -> k (Ctx i x)

addCtx :: Name -> Dom Type -> ReduceM a -> ReduceM a
addCtx x a ret = do
  ctx <- asks $ map (nameConcrete . fst . unDom . ctxEntry) . envContext
  let x' = head $ filter (notTaken ctx) $ iterate nextName x
  mkContextEntry ((x',) <$> a) $ \ce ->
    local (\e -> e { envContext = ce : envContext e }) ret
      -- let-bindings keep track of own their context
  where
    notTaken xs x = isNoName x || nameConcrete x `notElem` xs

underAbstraction :: Subst a => Dom Type -> Abs a -> (a -> ReduceM b) -> ReduceM b
underAbstraction _ (NoAbs _ v) f = f v
underAbstraction t a f =
  withFreshName_ (realName $ absName a) $ \x -> addCtx x t $ f (absBody a)
  where
    realName s = if isNoName s then "x" else s

underAbstraction_ :: Subst a => Abs a -> (a -> ReduceM b) -> ReduceM b
underAbstraction_ = underAbstraction dummyDom

lookupMeta :: MetaId -> ReduceM MetaVariable
lookupMeta i = fromMaybe __IMPOSSIBLE__ . Map.lookup i <$> gets stMetaStore

isInstantiatedMeta :: MetaId -> ReduceM Bool
isInstantiatedMeta i = do
  mv <- lookupMeta i
  return $ case mvInstantiation mv of
    InstV{} -> True
    InstS{} -> True
    _       -> False

-- | Run a computation if a certain verbosity level is activated.
--
--   Precondition: The level must be non-negative.
verboseS :: VerboseKey -> Int -> ReduceM () -> ReduceM ()
verboseS k n action = whenM (hasVerbosity k n) action

reportSDoc :: VerboseKey -> Int -> TCM Doc -> ReduceM ()
reportSDoc k n doc = return () -- Cannot implement this!

reportSLn :: VerboseKey -> Int -> String -> ReduceM ()
reportSLn k n s = return () -- Cannot implement this!

-- | Apply a function if a certain verbosity level is activated.
--
--   Precondition: The level must be non-negative.
{-# SPECIALIZE applyWhenVerboseS :: VerboseKey -> Int -> (ReduceM a -> ReduceM a) -> ReduceM a-> ReduceM a #-}
applyWhenVerboseS :: HasOptions m => VerboseKey -> Int -> (m a -> m a) -> m a -> m a
applyWhenVerboseS k n f a = ifM (hasVerbosity k n) (f a) a

traceSDoc :: VerboseKey -> Int -> TCM Doc -> ReduceM a -> ReduceM a
traceSDoc k n doc = applyWhenVerboseS k n $ \ cont -> do
  ReduceEnv env st <- askR
  -- return $! unsafePerformIO $ do print . fst =<< runTCM env st doc
  trace (show $ fst $ unsafePerformIO $ runTCM env st doc) cont

-- traceSDoc :: VerboseKey -> Int -> TCM Doc -> ReduceM a -> ReduceM a
-- traceSDoc k n doc = verboseS k n $ ReduceM $ do
--   ReduceEnv env st <- ask
--   -- return $! unsafePerformIO $ do print . fst =<< runTCM env st doc
--   trace (show $ fst $ unsafePerformIO $ runTCM env st doc) $ return ()

{-# SPECIALIZE traceSLn :: VerboseKey -> Int -> String -> ReduceM a -> ReduceM a #-}
traceSLn :: HasOptions m => VerboseKey -> Int -> String -> m a -> m a
traceSLn k n s = applyWhenVerboseS k n (trace s)

instance HasConstInfo ReduceM where
  getConstInfo q = ReduceM $ ReaderT $ \(ReduceEnv env st) -> Identity $
    let defs  = sigDefinitions $ stSignature st
        idefs = sigDefinitions $ stImports st
    in case catMaybes [HMap.lookup q defs, HMap.lookup q idefs] of
        []  -> trace ("Unbound name: " ++ show q ++ " " ++ showQNameId q) __IMPOSSIBLE__
        [d] -> mkAbs env d
        ds  -> trace ("Ambiguous name: " ++ show q) __IMPOSSIBLE__
    where
      mkAbs env d
        | treatAbstractly' q' env = fromMaybe err $ makeAbstract d
        | otherwise               = d
        where
          err = trace ("Not in scope: " ++ show q) __IMPOSSIBLE__
          q' = case theDef d of
            -- Hack to make abstract constructors work properly. The constructors
            -- live in a module with the same name as the datatype, but for 'abstract'
            -- purposes they're considered to be in the same module as the datatype.
            Constructor{} -> dropLastModule q
            _                 -> q

          dropLastModule q@QName{ qnameModule = m } =
            q{ qnameModule = mnameFromList $ init' $ mnameToList m }

          init' [] = {-'-} __IMPOSSIBLE__
          init' xs = init xs

