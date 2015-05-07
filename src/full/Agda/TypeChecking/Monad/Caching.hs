{-# LANGUAGE CPP #-}
{-# LANGUAGE PatternGuards #-}

module Agda.TypeChecking.Monad.Caching
  ( -- * Log reading/writing operations
    writeToCurrentLog
  , readFromCachedLog
  , cleanCachedLog
  , cacheCurrentLog

    -- * Activating
  , activateLoadedFileCache
  , cachingStarts

    -- * Restoring the 'PostScopeState'
  , restorePostScopeState
  ) where

import Control.Arrow ((***), first, second)
import Control.Applicative
import qualified Control.Exception as E
import Control.Monad.State
import Data.Set (Set)
import qualified Data.Map as Map
import qualified Data.Set as Set
import Data.Maybe (fromMaybe)

import Agda.Syntax.Common

import Agda.TypeChecking.Monad.Base
import Agda.TypeChecking.Monad.Options

import Agda.Utils.Lens

#include "undefined.h"
import Agda.Utils.Impossible

-- | To be called before any write or restore calls.
cachingStarts :: TCM ()
cachingStarts = do
    NameId _ m <- use stFreshNameId
    stFreshNameId .= NameId 1 m

-- | Writes a 'TypeCheckAction' to the current log, using the current
-- 'PostScopeState'
writeToCurrentLog :: TypeCheckAction -> TCM ()
writeToCurrentLog d = do
  reportSLn "cache" 10 $ "cachePostScopeState"
  l <- gets stPostScopeState
  modifyCache $ fmap $ \lfc -> lfc{ lfcCurrent = (d, l) : lfcCurrent lfc}

restorePostScopeState :: PostScopeState -> TCM ()
restorePostScopeState pss = do
  reportSLn "cache" 10 $ "restorePostScopeState"
  modify $ \s ->
    let ipoints = s^.stInteractionPoints
        pss' = pss{stPostInteractionPoints = stPostInteractionPoints pss `mergeIPMap` ipoints}
    in  s{stPostScopeState = pss'}
  where
    mergeIPMap lm sm = Map.mapWithKey (\k v -> maybe v (`mergeIP` v) (Map.lookup k lm)) sm
    mergeIP li si = si {ipMeta = ipMeta li}

modifyCache
  :: (Maybe LoadedFileCache -> Maybe LoadedFileCache)
  -> TCM ()
modifyCache f = do
  modify $ \s -> s
    { stPersistentState = let p = stPersistentState s
                          in p { stLoadedFileCache = f (stLoadedFileCache p)}
    }

getCache :: TCM (Maybe LoadedFileCache)
getCache = do
  gets (stLoadedFileCache . stPersistentState)

putCache :: Maybe LoadedFileCache -> TCM ()
putCache cs = modifyCache $ const cs

-- | Reads the next entry in the cached type check log, if present.
readFromCachedLog :: TCM (Maybe (TypeCheckAction, PostScopeState))
readFromCachedLog = do
  reportSLn "cache" 10 $ "getCachedTypeCheckAction"
  mbCache <- getCache
  case mbCache of
    Just lfc | (entry : entries) <- lfcCached lfc -> do
      putCache $ Just lfc{lfcCached = entries}
      return (Just entry)
    _ -> do
      return Nothing

-- | Empties the "to read" CachedState. To be used when it gets invalid.
cleanCachedLog :: TCM ()
cleanCachedLog = do
  reportSLn "cache" 10 $ "cleanCachedLog"
  modifyCache $ fmap $ \lfc -> lfc{lfcCached = []}

-- | Makes sure that the 'stLoadedFileCache' is 'Just', with a clean
-- current log. Crashes is 'stLoadedFileCache' is already active with a
-- dirty log.  Should be called when we start typechecking the current
-- file.
activateLoadedFileCache :: TCM ()
activateLoadedFileCache = do
  reportSLn "cache" 10 $ "activateLoadedFileCache"
  modifyCache $ \mbLfc -> case mbLfc of
    Nothing                          -> Just $ LoadedFileCache [] []
    Just lfc | null (lfcCurrent lfc) -> Just lfc
    _                                -> __IMPOSSIBLE__

-- | Caches the current type check log.  Discardes the old cache.  Does
-- nothing if caching is inactive.
cacheCurrentLog :: TCM ()
cacheCurrentLog = do
  reportSLn "cache" 10 $ "cacheCurrentTypeCheckLog"
  modifyCache $ fmap $ \lfc ->
    lfc{lfcCached = reverse (lfcCurrent lfc), lfcCurrent = []}
