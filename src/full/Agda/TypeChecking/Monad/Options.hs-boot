module Agda.TypeChecking.Monad.Options where

import Control.Monad.Trans
import Control.Monad.Reader

import Agda.Interaction.Options
import Agda.TypeChecking.Monad.Base
import Agda.Utils.FileName
import Agda.Utils.Pretty

getIncludeDirs :: TCM [AbsolutePath]

type VerboseKey = String

hasVerbosity :: HasOptions m => VerboseKey -> Int -> m Bool
verboseS :: (MonadReader TCEnv m, HasOptions m) => VerboseKey -> Int -> m () -> m ()
