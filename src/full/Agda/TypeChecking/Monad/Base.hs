{-# OPTIONS_GHC -fwarn-missing-signatures #-}

{-# LANGUAGE CPP                        #-}
{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE DeriveFoldable             #-}
{-# LANGUAGE DeriveFunctor              #-}
{-# LANGUAGE DeriveTraversable          #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE NamedFieldPuns             #-}
{-# LANGUAGE Rank2Types                 #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TypeSynonymInstances       #-}
{-# LANGUAGE UndecidableInstances       #-}

module Agda.TypeChecking.Monad.Base where

import Control.Arrow ((***), first, second)
import qualified Control.Concurrent as C
import Control.DeepSeq
import Control.Exception as E
import Control.Monad.State
import Control.Monad.Reader
import Control.Monad.Writer
import Control.Monad.Trans.Maybe
import Control.Applicative

import Data.Function
import Data.Int
import qualified Data.List as List
import Data.Maybe
import Data.Map as Map
import Data.Set as Set
import Data.Typeable (Typeable)
import Data.Foldable
import Data.Traversable
import Data.IORef

import Agda.Syntax.Concrete (TopLevelModuleName)
import Agda.Syntax.Common hiding (Arg, Dom, NamedArg, ArgInfo)
import qualified Agda.Syntax.Common as Common
import qualified Agda.Syntax.Concrete as C
import qualified Agda.Syntax.Concrete.Definitions as D
import qualified Agda.Syntax.Abstract as A
import Agda.Syntax.Internal as I
import Agda.Syntax.Internal.Pattern ()
import Agda.Syntax.Position
import Agda.Syntax.Scope.Base

import Agda.TypeChecking.CompiledClause

import Agda.Interaction.Exceptions
-- import {-# SOURCE #-} Agda.Interaction.FindFile
import Agda.Interaction.Options
import {-# SOURCE #-} Agda.Interaction.Response
  (InteractionOutputCallback, defaultInteractionOutputCallback, Response)
import Agda.Interaction.Highlighting.Precise
  (CompressedFile, HighlightingInfo)

import qualified Agda.Compiler.JS.Syntax as JS

import Agda.TypeChecking.Monad.Base.Benchmark (Benchmark)
import qualified Agda.TypeChecking.Monad.Base.Benchmark as Benchmark

import Agda.Utils.Except
  ( Error(noMsg, strMsg)
  , ExceptT
  , MonadError(catchError, throwError)
  )

import Agda.Utils.FileName
import Agda.Utils.Fresh
import Agda.Utils.HashMap as HMap
import Agda.Utils.Hash
import Agda.Utils.Permutation
import Agda.Utils.Pretty
import Agda.Utils.Time

#include "undefined.h"
import Agda.Utils.Impossible

---------------------------------------------------------------------------
-- * Type checking state
---------------------------------------------------------------------------

data TCState =
    TCSt { stFreshThings       :: FreshThings
         , stSyntaxInfo        :: CompressedFile
           -- ^ Highlighting info.
         , stTokens            :: CompressedFile
           -- ^ Highlighting info for tokens (but not those tokens for
           -- which highlighting exists in 'stSyntaxInfo').
         , stMetaStore         :: MetaStore
         , stInteractionPoints :: InteractionPoints
         , stAwakeConstraints    :: Constraints
         , stSleepingConstraints :: Constraints
         , stDirty               :: Bool
         , stOccursCheckDefs   :: Set QName
           -- ^ Definitions to be considered during occurs check.
           --   Initialized to the current mutual block before the check.
           --   During occurs check, we remove definitions from this set
           --   as soon we have checked them.
         , stSignature         :: Signature
           -- ^ Declared identifiers of the current file.
           --   These will be serialized after successful type checking.
         , stImports           :: Signature
           -- ^ Imported declared identifiers.
           --   Those most not be serialized!
         , stImportedModules   :: Set ModuleName
         , stModuleToSource    :: ModuleToSource
         , stVisitedModules    :: VisitedModules
         , stCurrentModule     :: Maybe ModuleName
           -- ^ The current module is available after it has been type
           -- checked.
         , stScope             :: ScopeInfo
         , stPatternSyns       :: A.PatternSynDefns
           -- ^ Pattern synonyms of the current file.  Serialized.
         , stPatternSynImports :: A.PatternSynDefns
           -- ^ Imported pattern synonyms.  Must not be serialized!
         , stInstanceDefs      :: TempInstanceTable
         , stPragmaOptions     :: PragmaOptions
           -- ^ Options applying to the current file. @OPTIONS@
           -- pragmas only affect this field.
         , stStatistics        :: Statistics
           -- ^ Counters to collect various statistics about meta variables etc.
           --   Only for current file.
         , stMutualBlocks      :: Map MutualId (Set QName)
         , stLocalBuiltins     :: BuiltinThings PrimFun
         , stImportedBuiltins  :: BuiltinThings PrimFun
         , stHaskellImports    :: Set String
           -- ^ Imports that should be generated by the compiler (this
           -- includes imports from imported modules).
         , stPersistent        :: PersistentTCState
           -- ^ Options which apply to all files, unless overridden.
         }

-- | A part of the state which is not reverted when an error is thrown
-- or the state is reset.

data PersistentTCState = PersistentTCSt
  { stDecodedModules    :: DecodedModules
  , stPersistentOptions :: CommandLineOptions
  , stInteractionOutputCallback  :: InteractionOutputCallback
    -- ^ Callback function to call when there is a response
    --   to give to the interactive frontend.
    --   See the documentation of 'InteractionOutputCallback'.
  , stBenchmark         :: !Benchmark
    -- ^ Structure to track how much CPU time was spent on which Agda phase.
    --   Needs to be a strict field to avoid space leaks!
  , stAccumStatistics   :: !Statistics
  }

-- | Empty persistent state.

initPersistentState :: PersistentTCState
initPersistentState = PersistentTCSt
  { stPersistentOptions         = defaultOptions
  , stDecodedModules            = Map.empty
  , stInteractionOutputCallback = defaultInteractionOutputCallback
  , stBenchmark                 = Benchmark.empty
  , stAccumStatistics           = Map.empty
  }

data FreshThings =
        Fresh { fMeta        :: MetaId
              , fInteraction :: InteractionId
              , fMutual      :: MutualId
              , fName        :: NameId
              , fCtx         :: CtxId
              , fProblem     :: ProblemId
              , fInt         :: Int
                -- ^ Can be used for various things.
              }
    deriving (Show)

-- | Empty state of type checker.

initState :: TCState
initState = TCSt
  { stFreshThings          = (Fresh 0 0 0 (NameId 0 0) 0 0 0) { fProblem = 1 }
  , stMetaStore            = Map.empty
  , stSyntaxInfo           = mempty
  , stTokens               = mempty
  , stInteractionPoints    = Map.empty
  , stAwakeConstraints     = []
  , stSleepingConstraints  = []
  , stDirty                = False
  , stOccursCheckDefs      = Set.empty
  , stSignature            = emptySignature
  , stImports              = emptySignature
  , stImportedModules      = Set.empty
  , stModuleToSource       = Map.empty
  , stVisitedModules       = Map.empty
  , stCurrentModule        = Nothing
  , stScope                = emptyScopeInfo
  , stPatternSyns          = Map.empty
  , stPatternSynImports    = Map.empty
  , stInstanceDefs         = (Map.empty , [])
  , stPragmaOptions        = defaultInteractionOptions
  , stStatistics           = Map.empty
  , stMutualBlocks         = Map.empty
  , stLocalBuiltins        = Map.empty
  , stImportedBuiltins     = Map.empty
  , stHaskellImports       = Set.empty
  , stPersistent           = initPersistentState
  }

stBuiltinThings :: TCState -> BuiltinThings PrimFun
stBuiltinThings s = stLocalBuiltins s `Map.union` stImportedBuiltins s

instance HasFresh MetaId FreshThings where
    nextFresh s = (i, s { fMeta = i + 1 })
        where
            i = fMeta s

instance HasFresh MutualId FreshThings where
    nextFresh s = (i, s { fMutual = i + 1 })
        where
            i = fMutual s

instance HasFresh InteractionId FreshThings where
    nextFresh s = (i, s { fInteraction = i + 1 })
        where
            i = fInteraction s

instance HasFresh NameId FreshThings where
    nextFresh s = (i, s { fName = succ i })
        where
            i = fName s

instance HasFresh CtxId FreshThings where
    nextFresh s = (i, s { fCtx = succ i })
        where
            i = fCtx s

instance HasFresh Int FreshThings where
    nextFresh s = (i, s { fInt = succ i })
        where
            i = fInt s

newtype ProblemId = ProblemId Nat
  deriving (Typeable, Eq, Ord, Enum, Real, Integral, Num)

instance Show ProblemId where
  show (ProblemId n) = show n

instance HasFresh ProblemId FreshThings where
  nextFresh s = (i, s { fProblem = succ i })
    where i = fProblem s

instance HasFresh i FreshThings => HasFresh i TCState where
    nextFresh s = ((,) $! i) $! s { stFreshThings = f }
        where
            (i, f) = nextFresh $ stFreshThings s


---------------------------------------------------------------------------
-- ** Managing file names
---------------------------------------------------------------------------

-- | Maps top-level module names to the corresponding source file
-- names.

type ModuleToSource = Map TopLevelModuleName AbsolutePath

-- | Maps source file names to the corresponding top-level module
-- names.

type SourceToModule = Map AbsolutePath TopLevelModuleName

-- | Creates a 'SourceToModule' map based on 'stModuleToSource'.

sourceToModule :: TCM SourceToModule
sourceToModule =
  Map.fromList
     .  List.map (\(m, f) -> (f, m))
     .  Map.toList
    <$> gets stModuleToSource

---------------------------------------------------------------------------
-- ** Interface
---------------------------------------------------------------------------

data ModuleInfo = ModuleInfo
  { miInterface  :: Interface
  , miWarnings   :: Bool
    -- ^ 'True' if warnings were encountered when the module was type
    -- checked.
  }

-- Note that the use of 'C.TopLevelModuleName' here is a potential
-- performance problem, because these names do not contain unique
-- identifiers.

type VisitedModules = Map C.TopLevelModuleName ModuleInfo
type DecodedModules = Map C.TopLevelModuleName Interface

data Interface = Interface
  { iSourceHash      :: Hash
    -- ^ Hash of the source code.
  , iImportedModules :: [(ModuleName, Hash)]
    -- ^ Imported modules and their hashes.
  , iModuleName      :: ModuleName
    -- ^ Module name of this interface.
  , iScope           :: Map ModuleName Scope
  , iInsideScope     :: ScopeInfo
    -- ^ Scope after we loaded this interface.
    --   Used in 'Agda.Interaction.BasicOps.AtTopLevel'
    --   and     'Agda.Interaction.CommandLine.CommandLine.interactionLoop'.
  , iSignature       :: Signature
  , iBuiltin         :: BuiltinThings (String, QName)
  , iHaskellImports  :: Set String
                        -- ^ Haskell imports listed in
                        -- (transitively) imported modules are
                        -- not included here.
  , iHighlighting    :: HighlightingInfo
  , iPragmaOptions   :: [OptionsPragma]
                        -- ^ Pragma options set in the file.
  , iPatternSyns     :: A.PatternSynDefns
  }
  deriving (Typeable, Show)

-- | Combines the source hash and the (full) hashes of the imported modules.
iFullHash :: Interface -> Hash
iFullHash i = combineHashes $ iSourceHash i : List.map snd (iImportedModules i)

---------------------------------------------------------------------------
-- ** Closure
---------------------------------------------------------------------------

data Closure a = Closure { clSignature  :: Signature
                         , clEnv        :: TCEnv
                         , clScope      :: ScopeInfo
                         , clValue      :: a
                         }
    deriving (Typeable)

instance Show a => Show (Closure a) where
  show cl = "Closure " ++ show (clValue cl)

instance HasRange a => HasRange (Closure a) where
    getRange = getRange . clValue

buildClosure :: a -> TCM (Closure a)
buildClosure x = do
    env   <- ask
    sig   <- gets stSignature
    scope <- gets stScope
    return $ Closure sig env scope x

---------------------------------------------------------------------------
-- ** Constraints
---------------------------------------------------------------------------

type Constraints = [ProblemConstraint]

data ProblemConstraint = PConstr
  { constraintProblem :: ProblemId
  , theConstraint     :: Closure Constraint
  }
  deriving (Typeable, Show)

instance HasRange ProblemConstraint where
  getRange = getRange . theConstraint

data Constraint
  = ValueCmp Comparison Type Term Term
  | ElimCmp [Polarity] Type Term [Elim] [Elim]
  | TypeCmp Comparison Type Type
  | TelCmp Type Type Comparison Telescope Telescope -- ^ the two types are for the error message only
  | SortCmp Comparison Sort Sort
  | LevelCmp Comparison Level Level
--  | ShortCut MetaId Term Type
--    -- ^ A delayed instantiation.  Replaces @ValueCmp@ in 'postponeTypeCheckingProblem'.
  | UnBlock MetaId
  | Guarded Constraint ProblemId
  | IsEmpty Range Type
    -- ^ the range is the one of the absurd pattern
  | FindInScope MetaId (Maybe MetaId) (Maybe [(Term, Type)])
    -- ^ the first argument is the instance argument, the second one is the meta
    --   on which the constraint may be blocked on and the third one is the list
    --   of candidates (or Nothing if we haven’t determined the list of
    --   candidates yet)
  deriving (Typeable, Show)

instance HasRange Constraint where
  getRange (IsEmpty r t) = r
  getRange _ = noRange
{- no Range instances for Term, Type, Elm, Tele, Sort, Level, MetaId
  getRange (ValueCmp cmp a u v) = getRange (a,u,v)
  getRange (ElimCmp pol a v es es') = getRange (a,v,es,es')
  getRange (TypeCmp cmp a b) = getRange (a,b)
  getRange (TelCmp a b cmp tel tel') = getRange (a,b,tel,tel')
  getRange (SortCmp cmp s s') = getRange (s,s')
  getRange (LevelCmp cmp l l') = getRange (l,l')
  getRange (UnBlock x) = getRange x
  getRange (Guarded c pid) = getRange c
  getRange (FindInScope x cands) = getRange x
-}

data Comparison = CmpEq | CmpLeq
  deriving (Eq, Typeable)

instance Show Comparison where
  show CmpEq  = "="
  show CmpLeq = "=<"

-- | An extension of 'Comparison' to @>=@.
data CompareDirection = DirEq | DirLeq | DirGeq
  deriving (Eq, Typeable)

instance Show CompareDirection where
  show DirEq  = "="
  show DirLeq = "=<"
  show DirGeq = ">="

-- | Embed 'Comparison' into 'CompareDirection'.
fromCmp :: Comparison -> CompareDirection
fromCmp CmpEq  = DirEq
fromCmp CmpLeq = DirLeq

-- | Flip the direction of comparison.
flipCmp :: CompareDirection -> CompareDirection
flipCmp DirEq  = DirEq
flipCmp DirLeq = DirGeq
flipCmp DirGeq = DirLeq

-- | Turn a 'Comparison' function into a 'CompareDirection' function.
--
--   Property: @dirToCmp f (fromCmp cmp) = f cmp@
dirToCmp :: (Comparison -> a -> a -> c) -> CompareDirection -> a -> a -> c
dirToCmp cont DirEq  = cont CmpEq
dirToCmp cont DirLeq = cont CmpLeq
dirToCmp cont DirGeq = flip $ cont CmpLeq

---------------------------------------------------------------------------
-- * Open things
---------------------------------------------------------------------------

-- | A thing tagged with the context it came from.
data Open a = OpenThing { openThingCtxIds :: [CtxId], openThing :: a }
    deriving (Typeable, Show, Functor)

---------------------------------------------------------------------------
-- * Judgements
--
-- Used exclusively for typing of meta variables.
---------------------------------------------------------------------------

data Judgement t a
        = HasType { jMetaId :: a, jMetaType :: t }
        | IsSort  { jMetaId :: a, jMetaType :: t } -- Andreas, 2011-04-26: type needed for higher-order sort metas
    deriving (Typeable, Functor, Foldable, Traversable)

instance (Show t, Show a) => Show (Judgement t a) where
    show (HasType a t) = show a ++ " : " ++ show t
    show (IsSort  a t) = show a ++ " :sort " ++ show t

---------------------------------------------------------------------------
-- ** Meta variables
---------------------------------------------------------------------------

data MetaVariable =
        MetaVar { mvInfo          :: MetaInfo
                , mvPriority      :: MetaPriority -- ^ some metavariables are more eager to be instantiated
                , mvPermutation   :: Permutation
                  -- ^ a metavariable doesn't have to depend on all variables
                  --   in the context, this "permutation" will throw away the
                  --   ones it does not depend on
                , mvJudgement     :: Judgement Type MetaId
                , mvInstantiation :: MetaInstantiation
                , mvListeners     :: Set Listener -- ^ meta variables scheduled for eta-expansion but blocked by this one
                , mvFrozen        :: Frozen -- ^ are we past the point where we can instantiate this meta variable?
                }
    deriving (Typeable)

data Listener = EtaExpand MetaId
              | CheckConstraint Nat ProblemConstraint
  deriving (Typeable)

instance Eq Listener where
  EtaExpand       x   == EtaExpand       y   = x == y
  CheckConstraint x _ == CheckConstraint y _ = x == y
  _ == _ = False

instance Ord Listener where
  EtaExpand       x   `compare` EtaExpand       y   = x `compare` y
  CheckConstraint x _ `compare` CheckConstraint y _ = x `compare` y
  EtaExpand{} `compare` CheckConstraint{} = LT
  CheckConstraint{} `compare` EtaExpand{} = GT

-- | Frozen meta variable cannot be instantiated by unification.
--   This serves to prevent the completion of a definition by its use
--   outside of the current block.
--   (See issues 118, 288, 399).
data Frozen
  = Frozen        -- ^ Do not instantiate.
  | Instantiable
    deriving (Eq, Show)

data MetaInstantiation
        = InstV Term         -- ^ solved by term
        | InstS Term         -- ^ solved by @Lam .. Sort s@
        | Open               -- ^ unsolved
        | OpenIFS            -- ^ open, to be instantiated as "implicit from scope"
        | BlockedConst Term  -- ^ solution blocked by unsolved constraints
        | PostponedTypeCheckingProblem (Closure TypeCheckingProblem) (TCM Bool)
    deriving (Typeable)

data TypeCheckingProblem
  = CheckExpr A.Expr Type
  | CheckArgs ExpandHidden ExpandInstances Range [I.NamedArg A.Expr] Type Type (Args -> Type -> TCM Term)
  deriving (Typeable)

instance Show MetaInstantiation where
  show (InstV t) = "InstV (" ++ show t ++ ")"
  show (InstS s) = "InstS (" ++ show s ++ ")"
  show Open      = "Open"
  show OpenIFS   = "OpenIFS"
  show (BlockedConst t) = "BlockedConst (" ++ show t ++ ")"
  show (PostponedTypeCheckingProblem{}) = "PostponedTypeCheckingProblem (...)"

-- | Meta variable priority:
--   When we have an equation between meta-variables, which one
--   should be instantiated?
--
--   Higher value means higher priority to be instantiated.
newtype MetaPriority = MetaPriority Int
    deriving (Eq, Ord, Show)

data RunMetaOccursCheck
  = RunMetaOccursCheck
  | DontRunMetaOccursCheck
  deriving (Eq, Ord, Show)

-- | @MetaInfo@ is cloned from one meta to the next during pruning.
data MetaInfo = MetaInfo
  { miClosRange       :: Closure Range -- TODO: Not so nice. But we want both to have the environment of the meta (Closure) and its range.
--  , miRelevance       :: Relevance          -- ^ Created in irrelevant position?
  , miMetaOccursCheck :: RunMetaOccursCheck -- ^ Run the extended occurs check that goes in definitions?
  , miNameSuggestion  :: MetaNameSuggestion
    -- ^ Used for printing.
    --   @Just x@ if meta-variable comes from omitted argument with name @x@.
  }

-- | Name suggestion for meta variable.  Empty string means no suggestion.
type MetaNameSuggestion = String

-- | For printing, we couple a meta with its name suggestion.
data NamedMeta = NamedMeta
  { nmSuggestion :: MetaNameSuggestion
  , nmid         :: MetaId
  }

instance Show NamedMeta where
  show (NamedMeta "" x) = show x
  show (NamedMeta s  x) = "_" ++ s ++ show x

type MetaStore = Map MetaId MetaVariable

instance HasRange MetaInfo where
  getRange = clValue . miClosRange

instance HasRange MetaVariable where
    getRange m = getRange $ getMetaInfo m

instance SetRange MetaInfo where
  setRange r m = m { miClosRange = (miClosRange m) { clValue = r }}

instance SetRange MetaVariable where
  setRange r m = m { mvInfo = setRange r (mvInfo m) }

normalMetaPriority :: MetaPriority
normalMetaPriority = MetaPriority 0

lowMetaPriority :: MetaPriority
lowMetaPriority = MetaPriority (-10)

highMetaPriority :: MetaPriority
highMetaPriority = MetaPriority 10

getMetaInfo :: MetaVariable -> Closure Range
getMetaInfo = miClosRange . mvInfo

getMetaScope :: MetaVariable -> ScopeInfo
getMetaScope m = clScope $ getMetaInfo m

getMetaEnv :: MetaVariable -> TCEnv
getMetaEnv m = clEnv $ getMetaInfo m

getMetaSig :: MetaVariable -> Signature
getMetaSig m = clSignature $ getMetaInfo m

getMetaRelevance :: MetaVariable -> Relevance
getMetaRelevance = envRelevance . getMetaEnv

getMetaColors :: MetaVariable -> [Color]
getMetaColors = envColors . getMetaEnv

---------------------------------------------------------------------------
-- ** Interaction meta variables
---------------------------------------------------------------------------

-- | Interaction points are created by the scope checker who sets the range.
--   The meta variable is created by the type checker and then hooked up to the
--   interaction point.
data InteractionPoint = InteractionPoint
  { ipRange :: Range        -- ^ The position of the interaction point.
  , ipMeta  :: Maybe MetaId -- ^ The meta variable, if any, holding the type etc.
  }

instance Eq InteractionPoint where (==) = (==) `on` ipMeta

-- | Data structure managing the interaction points.
type InteractionPoints = Map InteractionId InteractionPoint

---------------------------------------------------------------------------
-- ** Signature
---------------------------------------------------------------------------

data Signature = Sig
      { sigSections    :: Sections
      , sigDefinitions :: Definitions
      }
  deriving (Typeable, Show)

type Sections    = Map ModuleName Section
type Definitions = HashMap QName Definition

data Section = Section
      { secTelescope :: Telescope
      , secFreeVars  :: Nat         -- ^ This is the number of parameters when
                                    --   we're inside the section and 0
                                    --   outside. It's used to know how much of
                                    --   the context to apply function from the
                                    --   section to when translating from
                                    --   abstract to internal syntax.
      }
  deriving (Typeable, Show)

emptySignature :: Signature
emptySignature = Sig Map.empty HMap.empty

-- | A @DisplayForm@ is in essence a rewrite rule
--   @
--      q ts --> dt
--   @
--   for a defined symbol (could be a constructor as well) @q@.
--   The right hand side is a 'DisplayTerm' which is used to
--   'reify' to a more readable 'Abstract.Syntax'.
--
--   The patterns @ts@ are just terms, but @var 0@ is interpreted
--   as a hole.  Each occurrence of @var 0@ is a new hole (pattern var).
--   For each *occurrence* of @var0@ the rhs @dt@ has a free variable.
--   These are instantiated when matching a display form against a
--   term @q vs@ succeeds.
data DisplayForm = Display
  { dfFreeVars :: Nat
    -- ^ Number @n@ of free variables in 'dfRHS'.
  , dfPats     :: [Term]
    -- ^ Left hand side patterns, where @var 0@ stands for a pattern
    --   variable.  There should be @n@ occurrences of @var0@ in
    --   'dfPats'.
  , dfRHS      :: DisplayTerm
    -- ^ Right hand side, with @n@ free variables.
  }
  deriving (Typeable, Show)

-- | A structured presentation of a 'Term' for reification into
--   'Abstract.Syntax'.
data DisplayTerm
  = DWithApp DisplayTerm [DisplayTerm] Args
    -- ^ @(f vs | ws) us@.
    --   The first 'DisplayTerm' is the parent function @f@ with its args @vs@.
    --   The list of 'DisplayTerm's are the with expressions @ws@.
    --   The 'Args' are additional arguments @us@
    --   (possible in case the with-application is of function type).
  | DCon ConHead [Arg DisplayTerm]
    -- ^ @c vs@.
  | DDef QName [Arg DisplayTerm]
    -- ^ @d vs@.
  | DDot Term
    -- ^ @.v@.
  | DTerm Term
    -- ^ @v@.
  deriving (Typeable, Show)

-- | By default, we have no display form.
defaultDisplayForm :: QName -> [Open DisplayForm]
defaultDisplayForm c = []

defRelevance :: Definition -> Relevance
defRelevance = argInfoRelevance . defArgInfo

defColors :: Definition -> [Color]
defColors = argInfoColors . defArgInfo

type RewriteRules = [RewriteRule]

-- | Rewrite rules can be added independently from function clauses.
data RewriteRule = RewriteRule
  { rewName    :: QName      -- ^ Name of rewrite rule @q : Γ → lhs ≡ rhs@
                             --   where @≡@ is the rewrite relation.
  , rewContext :: Telescope  -- ^ @Γ@.
  , rewLHS     :: Term       -- ^ @Γ ⊢ lhs : t@.
  , rewRHS     :: Term       -- ^ @Γ ⊢ rhs : t@.
  , rewType    :: Type       -- ^ @Γ ⊢ t@.
  }
    deriving (Typeable, Show)

data Definition = Defn
  { defArgInfo        :: ArgInfo -- ^ Hiding should not be used.
  , defName           :: QName
  , defType           :: Type    -- ^ Type of the lifted definition.
  , defPolarity       :: [Polarity]
  , defArgOccurrences :: [Occurrence]
  , defDisplay        :: [Open DisplayForm]
  , defMutual         :: MutualId
  , defCompiledRep    :: CompiledRepresentation
  , defRewriteRules   :: RewriteRules
    -- ^ Rewrite rules for this symbol, (additional to function clauses).
  , defInstance       :: Maybe QName
    -- ^ @Just q@ when this definition is an instance of class q
  , theDef            :: Defn
  }
    deriving (Typeable, Show)

-- | Create a definition with sensible defaults.
defaultDefn :: ArgInfo -> QName -> Type -> Defn -> Definition
defaultDefn info x t def = Defn
  { defArgInfo        = info
  , defName           = x
  , defType           = t
  , defPolarity       = []
  , defArgOccurrences = []
  , defDisplay        = defaultDisplayForm x
  , defMutual         = 0
  , defCompiledRep    = noCompiledRep
  , defRewriteRules   = []
  , defInstance       = Nothing
  , theDef            = def
  }

type HaskellCode = String
type HaskellType = String
type EpicCode    = String
type JSCode      = JS.Exp

data HaskellRepresentation
      = HsDefn HaskellType HaskellCode
      | HsType HaskellType
  deriving (Typeable, Show)

data HaskellExport = HsExport HaskellType String deriving (Show, Typeable)

-- | Polarity for equality and subtype checking.
data Polarity
  = Covariant      -- ^ monotone
  | Contravariant  -- ^ antitone
  | Invariant      -- ^ no information (mixed variance)
  | Nonvariant     -- ^ constant
  deriving (Typeable, Show, Eq)

data CompiledRepresentation = CompiledRep
  { compiledHaskell :: Maybe HaskellRepresentation
  , exportHaskell   :: Maybe HaskellExport
  , compiledEpic    :: Maybe EpicCode
  , compiledJS      :: Maybe JSCode
  }
  deriving (Typeable, Show)

noCompiledRep :: CompiledRepresentation
noCompiledRep = CompiledRep Nothing Nothing Nothing Nothing

-- | Subterm occurrences for positivity checking.
--   The constructors are listed in increasing information they provide:
--   @Mixed <= JustPos <= StrictPos <= GuardPos <= Unused@
--   @Mixed <= JustNeg <= Unused@.
data Occurrence
  = Mixed     -- ^ Arbitrary occurrence (positive and negative).
  | JustNeg   -- ^ Negative occurrence.
  | JustPos   -- ^ Positive occurrence, but not strictly positive.
  | StrictPos -- ^ Strictly positive occurrence.
  | GuardPos  -- ^ Guarded strictly positive occurrence (i.e., under ∞).  For checking recursive records.
  | Unused    --  ^ No occurrence.
  deriving (Typeable, Show, Eq, Ord)

instance NFData Occurrence

-- | Additional information for projection 'Function's.
data Projection = Projection
  { projProper    :: Maybe QName
    -- ^ @Nothing@ if only projection-like, @Just q@ if record projection,
    --   where @q@ is the original projection name
    --   (current name could be from module app).
  , projFromType  :: QName
    -- ^ Type projected from.  Record type if @projProper = Just{}@.
  , projIndex     :: Int
    -- ^ Index of the record argument.
    --   Start counting with 1, because 0 means that
    --   it is already applied to the record.
    --   (Can happen in module instantiation.)
  , projDropPars  :: Term
    -- ^ Term @t@ to be be applied to record parameters and record value.
    --   The parameters will be dropped.
    --   In case of a proper projection, a postfix projection application
    --   will be created: @t = \ pars r -> r .p@
    --   In case of a projection-like function, just the function symbol
    --   is returned as 'Def':  @t = \ pars -> f@.
  , projArgInfo   :: I.ArgInfo
    -- ^ The info of the principal (record) argument.
  } deriving (Typeable, Show)

data Defn = Axiom
            -- ^ Postulate.
            { axATPRole :: Maybe ATPRole
              -- ^ ATP axiom or conjecture?
            , axATPHints :: [QName]
              -- ^ ATP hints for a conjecture.
            }
          | Function
            { funClauses        :: [Clause]
            , funCompiled       :: Maybe CompiledClauses
              -- ^ 'Nothing' while function is still type-checked.
              --   @Just cc@ after type and coverage checking and
              --   translation to case trees.
            , funInv            :: FunctionInverse
            , funMutual         :: [QName]
              -- ^ Mutually recursive functions, @data@s and @record@s.
              --   Does not include this function.
            , funAbstr          :: IsAbstract
            , funDelayed        :: Delayed
              -- ^ Are the clauses of this definition delayed?
            , funProjection     :: Maybe Projection
              -- ^ Is it a record projection?
              --   If yes, then return the name of the record type and index of
              --   the record argument.  Start counting with 1, because 0 means that
              --   it is already applied to the record. (Can happen in module
              --   instantiation.) This information is used in the termination
              --   checker.
            , funStatic         :: Bool
              -- ^ Should calls to this function be normalised at compile-time?
            , funCopy           :: Bool
              -- ^ Has this function been created by a module
                                   -- instantiation?
            , funTerminates     :: Maybe Bool
              -- ^ Has this function been termination checked?  Did it pass?
            , funExtLam         :: Maybe (Int,Int)
              -- ^ Is this function generated from an extended lambda?
              --   If yes, then return the number of hidden and non-hidden lambda-lifted arguments
            , funWith           :: Maybe QName
              -- ^ Is this a generated with-function? If yes, then what's the
              --   name of the parent function.
            , funCopatternLHS   :: Bool
              -- ^ Is this a function defined by copatterns?
            , funATPRole        :: Maybe ATPRole
              -- ^ ATP definition or hint?
            }
          | Datatype
            { dataPars           :: Nat            -- ^ Number of parameters.
            , dataSmallPars      :: Permutation    -- ^ Parameters that are maybe small.
            , dataNonLinPars     :: Drop Permutation  -- ^ Parameters that appear in indices.
            , dataIxs            :: Nat            -- ^ Number of indices.
            , dataInduction      :: Induction      -- ^ @data@ or @codata@ (legacy).
            , dataClause         :: (Maybe Clause) -- ^ This might be in an instantiated module.
            , dataCons           :: [QName]        -- ^ Constructor names.
            , dataSort           :: Sort
            , dataMutual         :: [QName]        -- ^ Mutually recursive functions, @data@s and @record@s.  Does not include this data type.
            , dataAbstr          :: IsAbstract
            }
          | Record
            { recPars           :: Nat                  -- ^ Number of parameters.
            , recClause         :: Maybe Clause
            , recConHead        :: ConHead              -- ^ Constructor name and fields.
            , recNamedCon       :: Bool
            , recConType        :: Type                 -- ^ The record constructor's type. (Includes record parameters.)
            , recFields         :: [Arg QName]
            , recTel            :: Telescope            -- ^ The record field telescope. (Includes record parameters.)
                                                        --   Note: @TelV recTel _ == telView' recConType@.
                                                        --   Thus, @recTel@ is redundant.
            , recMutual         :: [QName]              -- ^ Mutually recursive functions, @data@s and @record@s.  Does not include this record.
            , recEtaEquality    :: Bool                 -- ^ Eta-expand at this record type.  @False@ for unguarded recursive records and coinductive records.
            , recInduction      :: Maybe Induction
              -- ^ 'Inductive' or 'CoInductive'?  Matters only for recursive records.
              --   'Nothing' means that the user did not specify it, which is an error
              --   for recursive records.
            , recRecursive      :: Bool                 -- ^ Recursive record.  Implies @recEtaEquality = False@.  Projections are not size-preserving.
            , recAbstr          :: IsAbstract
            }
          | Constructor
            { conPars   :: Nat         -- ^ Number of parameters.
            , conSrcCon :: ConHead     -- ^ Name of (original) constructor and fields. (This might be in a module instance.)
            , conData   :: QName       -- ^ Name of datatype or record type.
            , conAbstr  :: IsAbstract
            , conInd    :: Induction   -- ^ Inductive or coinductive?
            , conATPRole :: Maybe ATPRole -- ^ ATP axiom?
            }
          | Primitive
            { primAbstr :: IsAbstract
            , primName  :: String
            , primClauses :: [Clause]
              -- ^ 'null' for primitive functions, @not null@ for builtin functions.
            , primCompiled :: Maybe CompiledClauses
              -- ^ 'Nothing' for primitive functions,
              --   @'Just' something@ for builtin functions.
            }
            -- ^ Primitive or builtin functions.
    deriving (Typeable, Show)

-- | A template for creating 'Function' definitions, with sensible defaults.
emptyFunction :: Defn
emptyFunction = Function
  { funClauses     = []
  , funCompiled    = Nothing
  , funInv         = NotInjective
  , funMutual      = []
  , funAbstr       = ConcreteDef
  , funDelayed     = NotDelayed
  , funProjection  = Nothing
  , funStatic      = False
  , funCopy        = False
  , funTerminates  = Nothing
  , funExtLam      = Nothing
  , funWith        = Nothing
  , funCopatternLHS = False
  , funATPRole     = Nothing
  }

isCopatternLHS :: [Clause] -> Bool
isCopatternLHS = List.any (List.any (isJust . A.isProjP) . clausePats)

recCon :: Defn -> QName
recCon Record{ recConHead } = conName recConHead
recCon _ = __IMPOSSIBLE__

defIsRecord :: Defn -> Bool
defIsRecord Record{} = True
defIsRecord _        = False

defIsDataOrRecord :: Defn -> Bool
defIsDataOrRecord Record{}   = True
defIsDataOrRecord Datatype{} = True
defIsDataOrRecord _          = False

newtype Fields = Fields [(C.Name, Type)]
  deriving (Typeable)

-- | Did we encounter a simplifying reduction?
--   In terms of CIC, that would be a iota-reduction.
--   In terms of Agda, this is a constructor or literal
--   pattern that matched.
--   Just beta-reduction (substitution) or delta-reduction
--   (unfolding of definitions) does not count as simplifying?

data Simplification = YesSimplification | NoSimplification
  deriving (Typeable, Eq, Show)

instance Monoid Simplification where
  mempty = NoSimplification
  mappend YesSimplification _ = YesSimplification
  mappend NoSimplification  s = s

data Reduced no yes = NoReduction no | YesReduction Simplification yes
    deriving (Typeable, Functor)

-- | Three cases: 1. not reduced, 2. reduced, but blocked, 3. reduced, not blocked.
data IsReduced
  = NotReduced
  | Reduced    (Blocked ())

data MaybeReduced a = MaybeRed
  { isReduced     :: IsReduced
  , ignoreReduced :: a
  }
  deriving (Functor)

instance IsProjElim e => IsProjElim (MaybeReduced e) where
  isProjElim = isProjElim . ignoreReduced

type MaybeReducedArgs = [MaybeReduced (Arg Term)]
type MaybeReducedElims = [MaybeReduced Elim]

notReduced :: a -> MaybeReduced a
notReduced x = MaybeRed NotReduced x

reduced :: Blocked (Arg Term) -> MaybeReduced (Arg Term)
reduced b = case fmap ignoreSharing <$> b of
  NotBlocked (Common.Arg _ (MetaV x _)) -> MaybeRed (Reduced $ Blocked x ()) v
  _                                     -> MaybeRed (Reduced $ () <$ b)      v
  where
    v = ignoreBlocking b

-- | Controlling 'reduce'.
data AllowedReduction
  = ProjectionReductions     -- ^ (Projection and) projection-like functions may be reduced.
  | FunctionReductions       -- ^ Functions which are not projections may be reduced.
  | LevelReductions          -- ^ Reduce @'Level'@ terms.
  | NonTerminatingReductions -- ^ Functions that have not passed termination checking.
  deriving (Show, Eq, Ord, Enum, Bounded)

type AllowedReductions = [AllowedReduction]

-- | Not quite all reductions (skip non-terminating reductions)
allReductions :: AllowedReductions
allReductions = [minBound..pred maxBound]

data PrimFun = PrimFun
        { primFunName           :: QName
        , primFunArity          :: Arity
        , primFunImplementation :: [Arg Term] -> ReduceM (Reduced MaybeReducedArgs Term)
        }
    deriving (Typeable)

defClauses :: Definition -> [Clause]
defClauses Defn{theDef = Function{funClauses = cs}}        = cs
defClauses Defn{theDef = Primitive{primClauses = cs}}      = cs
defClauses Defn{theDef = Datatype{dataClause = Just c}}    = [c]
defClauses Defn{theDef = Record{recClause = Just c}}       = [c]
defClauses _                                               = []

defCompiled :: Definition -> Maybe CompiledClauses
defCompiled Defn{theDef = Function {funCompiled  = mcc}} = mcc
defCompiled Defn{theDef = Primitive{primCompiled = mcc}} = mcc
defCompiled _ = Nothing

defJSDef :: Definition -> Maybe JSCode
defJSDef = compiledJS . defCompiledRep

defEpicDef :: Definition -> Maybe EpicCode
defEpicDef = compiledEpic . defCompiledRep

-- | Are the clauses of this definition delayed?
defDelayed :: Definition -> Delayed
defDelayed Defn{theDef = Function{funDelayed = d}} = d
defDelayed _                                       = NotDelayed

-- | Has the definition failed the termination checker?
defNonterminating :: Definition -> Bool
defNonterminating Defn{theDef = Function{funTerminates = Just False}} = True
defNonterminating _                                                   = False

-- | Is the definition just a copy created by a module instantiation?
defCopy :: Definition -> Bool
defCopy Defn{theDef = Function{funCopy = b}} = b
defCopy _                                    = False

defAbstract :: Definition -> IsAbstract
defAbstract d = case theDef d of
    Axiom{}                   -> ConcreteDef
    Function{funAbstr = a}    -> a
    Datatype{dataAbstr = a}   -> a
    Record{recAbstr = a}      -> a
    Constructor{conAbstr = a} -> a
    Primitive{primAbstr = a}  -> a

---------------------------------------------------------------------------
-- ** Injectivity
---------------------------------------------------------------------------

type FunctionInverse = FunctionInverse' Clause

data FunctionInverse' c
  = NotInjective
  | Inverse (Map TermHead c)
  deriving (Typeable, Show, Functor)

data TermHead = SortHead
              | PiHead
              | ConsHead QName
  deriving (Typeable, Eq, Ord, Show)

---------------------------------------------------------------------------
-- ** Mutual blocks
---------------------------------------------------------------------------

newtype MutualId = MutId Int32
  deriving (Typeable, Eq, Ord, Show, Num)

---------------------------------------------------------------------------
-- ** Statistics
---------------------------------------------------------------------------

type Statistics = Map String Integer

---------------------------------------------------------------------------
-- ** Trace
---------------------------------------------------------------------------

data Call = CheckClause Type A.SpineClause (Maybe Clause)
          | forall a. CheckPattern A.Pattern Telescope Type (Maybe a)
          | CheckLetBinding A.LetBinding (Maybe ())
          | InferExpr A.Expr (Maybe (Term, Type))
          | CheckExprCall A.Expr Type (Maybe Term)
          | CheckDotPattern A.Expr Term (Maybe Constraints)
          | CheckPatternShadowing A.SpineClause (Maybe ())
          | IsTypeCall A.Expr Sort (Maybe Type)
          | IsType_ A.Expr (Maybe Type)
          | InferVar Name (Maybe (Term, Type))
          | InferDef Range QName (Maybe (Term, Type))
          | CheckArguments Range [NamedArg A.Expr] Type Type (Maybe (Args, Type))
          | CheckDataDef Range Name [A.LamBinding] [A.Constructor] (Maybe ())
          | CheckRecDef Range Name [A.LamBinding] [A.Constructor] (Maybe ())
          | CheckConstructor QName Telescope Sort A.Constructor (Maybe ())
          | CheckFunDef Range Name [A.Clause] (Maybe ())
          | CheckPragma Range A.Pragma (Maybe ())
          | CheckPrimitive Range Name A.Expr (Maybe ())
          | CheckIsEmpty Range Type (Maybe ())
          | CheckWithFunctionType A.Expr (Maybe ())
          | CheckSectionApplication Range ModuleName A.ModuleApplication (Maybe ())
          | ScopeCheckExpr C.Expr (Maybe A.Expr)
          | ScopeCheckDeclaration D.NiceDeclaration (Maybe [A.Declaration])
          | ScopeCheckLHS C.Name C.Pattern (Maybe A.LHS)
          | forall a. NoHighlighting (Maybe a)
          | forall a. SetRange Range (Maybe a)  -- ^ used by 'setCurrentRange'
    deriving (Typeable)

instance HasRange Call where
    getRange (CheckClause _ c _)                   = getRange c
    getRange (CheckPattern p _ _ _)                = getRange p
    getRange (InferExpr e _)                       = getRange e
    getRange (CheckExprCall e _ _)                 = getRange e
    getRange (CheckLetBinding b _)                 = getRange b
    getRange (IsTypeCall e s _)                    = getRange e
    getRange (IsType_ e _)                         = getRange e
    getRange (InferVar x _)                        = getRange x
    getRange (InferDef _ f _)                      = getRange f
    getRange (CheckArguments r _ _ _ _)            = r
    getRange (CheckDataDef i _ _ _ _)              = getRange i
    getRange (CheckRecDef i _ _ _ _)               = getRange i
    getRange (CheckConstructor _ _ _ c _)          = getRange c
    getRange (CheckFunDef i _ _ _)                 = getRange i
    getRange (CheckPragma r _ _)                   = r
    getRange (CheckPrimitive i _ _ _)              = getRange i
    getRange CheckWithFunctionType{}               = noRange
    getRange (ScopeCheckExpr e _)                  = getRange e
    getRange (ScopeCheckDeclaration d _)           = getRange d
    getRange (ScopeCheckLHS _ p _)                 = getRange p
    getRange (CheckDotPattern e _ _)               = getRange e
    getRange (CheckPatternShadowing c _)           = getRange c
    getRange (SetRange r _)                        = r
    getRange (CheckSectionApplication r _ _ _)     = r
    getRange (CheckIsEmpty r _ _)                  = r
    getRange (NoHighlighting _)                    = noRange

---------------------------------------------------------------------------
-- ** Instance table
---------------------------------------------------------------------------

-- | The instance table is a @Map@ associating to every name of
--   record/data type/postulate its list of instances
type InstanceTable = Map QName [QName]

-- | When typechecking something of the following form:
--
--     instance
--       x : _
--       x = y
--
--   it's not yet known where to add @x@, so we add it to a list of
--   unresolved instances and we'll deal with it later.
type TempInstanceTable = (InstanceTable , [QName])

---------------------------------------------------------------------------
-- ** Builtin things
---------------------------------------------------------------------------

data BuiltinDescriptor
  = BuiltinData (TCM Type) [String]
  | BuiltinDataCons (TCM Type)
  | BuiltinPrim String (Term -> TCM ())
  | BuiltinPostulate Relevance (TCM Type)
  | BuiltinUnknown (Maybe (TCM Type)) (Term -> Type -> TCM ())
    -- ^ Builtin of any kind.
    --   Type can be checked (@Just t@) or inferred (@Nothing@).
    --   The second argument is the hook for the verification function.

data BuiltinInfo =
   BuiltinInfo { builtinName :: String
               , builtinDesc :: BuiltinDescriptor }

type BuiltinThings pf = Map String (Builtin pf)

data Builtin pf
        = Builtin Term
        | Prim pf
    deriving (Typeable, Show, Functor, Foldable, Traversable)

---------------------------------------------------------------------------
-- * Highlighting levels
---------------------------------------------------------------------------

-- | How much highlighting should be sent to the user interface?

data HighlightingLevel
  = None
  | NonInteractive
  | Interactive
    -- ^ This includes both non-interactive highlighting and
    -- interactive highlighting of the expression that is currently
    -- being type-checked.
    deriving (Eq, Ord, Show, Read)

-- | How should highlighting be sent to the user interface?

data HighlightingMethod
  = Direct
    -- ^ Via stdout.
  | Indirect
    -- ^ Both via files and via stdout.
    deriving (Eq, Show, Read)

-- | @ifTopLevelAndHighlightingLevelIs l m@ runs @m@ when we're
-- type-checking the top-level module and the highlighting level is
-- /at least/ @l@.

ifTopLevelAndHighlightingLevelIs ::
  MonadTCM tcm => HighlightingLevel -> tcm () -> tcm ()
ifTopLevelAndHighlightingLevelIs l m = do
  e <- ask
  when (envModuleNestingLevel e == 0 &&
        envHighlightingLevel e >= l)
       m

---------------------------------------------------------------------------
-- * Type checking environment
---------------------------------------------------------------------------

data TCEnv =
    TCEnv { envContext             :: Context
          , envLetBindings         :: LetBindings
          , envCurrentModule       :: ModuleName
          , envCurrentPath         :: AbsolutePath
            -- ^ The path to the file that is currently being
            -- type-checked.
          , envAnonymousModules    :: [(ModuleName, Nat)] -- ^ anonymous modules and their number of free variables
          , envImportPath          :: [C.TopLevelModuleName] -- ^ to detect import cycles
          , envMutualBlock         :: Maybe MutualId -- ^ the current (if any) mutual block
          , envSolvingConstraints  :: Bool
                -- ^ Are we currently in the process of solving active constraints?
          , envAssignMetas         :: Bool
            -- ^ Are we allowed to assign metas?
          , envActiveProblems      :: [ProblemId]
          , envAbstractMode        :: AbstractMode
                -- ^ When checking the typesignature of a public definition
                --   or the body of a non-abstract definition this is true.
                --   To prevent information about abstract things leaking
                --   outside the module.
          , envRelevance           :: Relevance
                -- ^ Are we checking an irrelevant argument? (=@Irrelevant@)
                -- Then top-level irrelevant declarations are enabled.
                -- Other value: @Relevant@, then only relevant decls. are avail.
          , envColors              :: [Color]
          , envDisplayFormsEnabled :: Bool
                -- ^ Sometimes we want to disable display forms.
          , envReifyInteractionPoints :: Bool
                -- ^ should we try to recover interaction points when reifying?
                --   disabled when generating types for with functions
          , envEtaContractImplicit :: Bool
                -- ^ it's safe to eta contract implicit lambdas as long as we're
                --   not going to reify and retypecheck (like when doing with
                --   abstraction)
          , envRange :: Range
          , envHighlightingRange :: Range
                -- ^ Interactive highlighting uses this range rather
                --   than 'envRange'.
          , envCall  :: Maybe (Closure Call)
                -- ^ what we're doing at the moment
          , envHighlightingLevel  :: HighlightingLevel
                -- ^ Set to 'None' when imported modules are
                --   type-checked.
          , envHighlightingMethod :: HighlightingMethod
          , envModuleNestingLevel :: Integer
                -- ^ This number indicates how far away from the
                --   top-level module Agda has come when chasing
                --   modules. The level of a given module is not
                --   necessarily the same as the length, in the module
                --   dependency graph, of the shortest path from the
                --   top-level module; it depends on in which order
                --   Agda chooses to chase dependencies.
          , envAllowDestructiveUpdate :: Bool
                -- ^ When True, allows destructively shared updating terms
                --   during evaluation or unification. This is disabled when
                --   doing speculative checking, like solve instance metas, or
                --   when updating might break abstraction, as is the case when
                --   checking abstract definitions.
          , envExpandLast :: ExpandHidden
                -- ^ When type-checking an alias f=e, we do not want
                -- to insert hidden arguments in the end, because
                -- these will become unsolved metas.
          , envAppDef :: Maybe QName
                -- ^ We are reducing an application of this function.
                -- (For debugging of incomplete matches only.)
          , envSimplification :: Simplification
                -- ^ Did we encounter a simplification (proper match)
                --   during the current reduction process?
          , envAllowedReductions :: AllowedReductions
          , envCompareBlocked :: Bool
                -- ^ Can we compare blocked things during conversion?
                --   No by default.
                --   Yes for rewriting feature.
          , envPrintDomainFreePi :: Bool
                -- ^ When True types will be omitted from printed pi types if they
                --   can be inferred
          , envInsideDotPattern :: Bool
                -- ^ Used by the scope checker to make sure that certain forms
                --   of expressions are not used inside dot patterns: extended
                --   lambdas and let-expressions.
          , envReifyUnquoted :: Bool
                -- ^ The rules for translating internal to abstract syntax are
                --   slightly different when the internal term comes from an
                --   unquote.
          }
    deriving (Typeable)

initEnv :: TCEnv
initEnv = TCEnv { envContext             = []
                , envLetBindings         = Map.empty
                , envCurrentModule       = noModuleName
                , envCurrentPath         = __IMPOSSIBLE__
                , envAnonymousModules    = []
                , envImportPath          = []
                , envMutualBlock         = Nothing
                , envSolvingConstraints  = False
                , envActiveProblems      = [0]
                , envAssignMetas         = True
                , envAbstractMode        = ConcreteMode
  -- Andreas, 2013-02-21:  This was 'AbstractMode' until now.
  -- However, top-level checks for mutual blocks, such as
  -- constructor-headedness, should not be able to look into
  -- abstract definitions unless abstract themselves.
  -- (See also discussion on issue 796.)
  -- The initial mode should be 'ConcreteMode', ensuring you
  -- can only look into abstract things in an abstract
  -- definition (which sets 'AbstractMode').
                , envRelevance           = Relevant
                , envColors              = []
                , envDisplayFormsEnabled = True
                , envReifyInteractionPoints = True
                , envEtaContractImplicit    = True
                , envRange                  = noRange
                , envHighlightingRange      = noRange
                , envCall                   = Nothing
                , envHighlightingLevel      = None
                , envHighlightingMethod     = Indirect
                , envModuleNestingLevel     = -1
                , envAllowDestructiveUpdate = True
                , envExpandLast             = ExpandLast
                , envAppDef                 = Nothing
                , envSimplification         = NoSimplification
                , envAllowedReductions      = allReductions
                , envCompareBlocked         = False
                , envPrintDomainFreePi      = False
                , envInsideDotPattern       = False
                , envReifyUnquoted          = False
                }

---------------------------------------------------------------------------
-- ** Context
---------------------------------------------------------------------------

-- | The @Context@ is a stack of 'ContextEntry's.
type Context      = [ContextEntry]
data ContextEntry = Ctx { ctxId    :: CtxId
                        , ctxEntry :: Dom (Name, Type)
                        }
  deriving (Typeable)

newtype CtxId     = CtxId Nat
  deriving (Typeable, Eq, Ord, Show, Enum, Real, Integral, Num)

---------------------------------------------------------------------------
-- ** Let bindings
---------------------------------------------------------------------------

type LetBindings = Map Name (Open (Term, Dom Type))

---------------------------------------------------------------------------
-- ** Abstract mode
---------------------------------------------------------------------------

data AbstractMode
  = AbstractMode        -- ^ Abstract things in the current module can be accessed.
  | ConcreteMode        -- ^ No abstract things can be accessed.
  | IgnoreAbstractMode  -- ^ All abstract things can be accessed.
  deriving (Typeable, Show)

---------------------------------------------------------------------------
-- ** Insertion of implicit arguments
---------------------------------------------------------------------------

data ExpandHidden
  = ExpandLast      -- ^ Add implicit arguments in the end until type is no longer hidden 'Pi'.
  | DontExpandLast  -- ^ Do not append implicit arguments.
  deriving (Eq)

data ExpandInstances
  = ExpandInstanceArguments
  | DontExpandInstanceArguments
    deriving (Eq)

---------------------------------------------------------------------------
-- * Type checking errors
---------------------------------------------------------------------------

-- Occurence of a name in a datatype definition
data Occ = OccCon { occDatatype :: QName
                  , occConstructor :: QName
                  , occPosition :: OccPos
                  }
         | OccClause { occFunction :: QName
                     , occClause   :: Int
                     , occPosition :: OccPos
                     }
  deriving (Show)

data OccPos = NonPositively | ArgumentTo Nat QName
  deriving (Show)

-- | Information about a call.

data CallInfo = CallInfo
  { callInfoTarget :: QName
    -- ^ Target function name pretty-printed.
  , callInfoRange :: Range
    -- ^ Range of the target function.
  , callInfoCall :: Closure Term
    -- ^ To be formatted representation of the call.
  } deriving Typeable

-- no Eq, Ord instances: too expensive! (see issues 851, 852)

-- | We only 'show' the name of the callee.
instance Show   CallInfo where show   = show . callInfoTarget
instance Pretty CallInfo where pretty = text . show

-- | Information about a mutual block which did not pass the
-- termination checker.

data TerminationError = TerminationError
  { termErrFunctions :: [QName]
    -- ^ The functions which failed to check. (May not include
    -- automatically generated functions.)
  , termErrCalls :: [CallInfo]
    -- ^ The problematic call sites.
  } deriving (Typeable, Show)


data SplitError = NotADatatype (Closure Type) -- ^ neither data type nor record
                | IrrelevantDatatype (Closure Type)   -- ^ data type, but in irrelevant position
                | CoinductiveDatatype (Closure Type)  -- ^ coinductive data type
{- UNUSED
                | NoRecordConstructor Type  -- ^ record type, but no constructor
 -}
                | CantSplit QName Telescope Args Args [Term]
                | GenericSplitError String
  deriving (Show)

instance Error SplitError where
  noMsg  = strMsg ""
  strMsg = GenericSplitError

data TypeError
        = InternalError String
        | NotImplemented String
        | NotSupported String
        | CompilationError String
        | TerminationCheckFailed [TerminationError]
        | PropMustBeSingleton
        | DataMustEndInSort Term
{- UNUSED
        | DataTooManyParameters
            -- ^ In @data D xs where@ the number of parameters @xs@ does not fit the
            --   the parameters given in the forward declaraion @data D Gamma : T@.
-}
        | ShouldEndInApplicationOfTheDatatype Type
            -- ^ The target of a constructor isn't an application of its
            -- datatype. The 'Type' records what it does target.
        | ShouldBeAppliedToTheDatatypeParameters Term Term
            -- ^ The target of a constructor isn't its datatype applied to
            --   something that isn't the parameters. First term is the correct
            --   target and the second term is the actual target.
        | ShouldBeApplicationOf Type QName
            -- ^ Expected a type to be an application of a particular datatype.
        | ConstructorPatternInWrongDatatype QName QName -- ^ constructor, datatype
        | IndicesNotConstructorApplications [Arg Term] -- ^ Indices.
        | IndexVariablesNotDistinct [Nat] [Arg Term] -- ^ Variables, indices.
        | IndicesFreeInParameters [Nat] [Arg Term] [Arg Term]
          -- ^ Indices (variables), index expressions (with
          -- constructors applied to reconstructed parameters),
          -- parameters.
        | CantResolveOverloadedConstructorsTargetingSameDatatype QName [QName]
          -- ^ Datatype, constructors.
        | DoesNotConstructAnElementOf QName Type -- ^ constructor, type
        | DifferentArities
            -- ^ Varying number of arguments for a function.
        | WrongHidingInLHS
            -- ^ The left hand side of a function definition has a hidden argument
            --   where a non-hidden was expected.
        | WrongHidingInLambda Type
            -- ^ Expected a non-hidden function and found a hidden lambda.
        | WrongHidingInApplication Type
            -- ^ A function is applied to a hidden argument where a non-hidden was expected.
        | WrongNamedArgument (I.NamedArg A.Expr)
            -- ^ A function is applied to a hidden named argument it does not have.
        | WrongIrrelevanceInLambda Type
            -- ^ Expected a relevant function and found an irrelevant lambda.
        | HidingMismatch Hiding Hiding
            -- ^ The given hiding does not correspond to the expected hiding.
        | RelevanceMismatch Relevance Relevance
            -- ^ The given relevance does not correspond to the expected relevane.
        | ColorMismatch [Color] [Color]
            -- ^ The given color does not correspond to the expected color.
        | NotInductive Term
          -- ^ The term does not correspond to an inductive data type.
        | UninstantiatedDotPattern A.Expr
        | IlltypedPattern A.Pattern Type
        | IllformedProjectionPattern A.Pattern
        | CannotEliminateWithPattern (A.NamedArg A.Pattern) Type
        | TooManyArgumentsInLHS Type
        | WrongNumberOfConstructorArguments QName Nat Nat
        | ShouldBeEmpty Type [Pattern]
        | ShouldBeASort Type
            -- ^ The given type should have been a sort.
        | ShouldBePi Type
            -- ^ The given type should have been a pi.
        | ShouldBeRecordType Type
        | ShouldBeRecordPattern Pattern
        | NotAProjectionPattern (A.NamedArg A.Pattern)
        | NotAProperTerm
        | SetOmegaNotValidType
        | InvalidType Term
            -- ^ This term is not a type expression.
        | SplitOnIrrelevant A.Pattern (Dom Type)
        | DefinitionIsIrrelevant QName
        | VariableIsIrrelevant Name
--        | UnequalLevel Comparison Term Term  -- UNUSED
        | UnequalTerms Comparison Term Term Type
        | UnequalTypes Comparison Type Type
--      | UnequalTelescopes Comparison Telescope Telescope -- UNUSED
        | UnequalRelevance Comparison Term Term
            -- ^ The two function types have different relevance.
        | UnequalHiding Term Term
            -- ^ The two function types have different hiding.
        | UnequalColors Term Term
            -- ^ The two function types have different color.
        | UnequalSorts Sort Sort
        | UnequalBecauseOfUniverseConflict Comparison Term Term
        | HeterogeneousEquality Term Type Term Type
            -- ^ We ended up with an equality constraint where the terms
            --   have different types.  This is not supported.
        | NotLeqSort Sort Sort
        | MetaCannotDependOn MetaId [Nat] Nat
            -- ^ The arguments are the meta variable, the parameters it can
            --   depend on and the paratemeter that it wants to depend on.
        | MetaOccursInItself MetaId
        | GenericError String
        | GenericDocError Doc
        | BuiltinMustBeConstructor String A.Expr
        | NoSuchBuiltinName String
        | DuplicateBuiltinBinding String Term Term
        | NoBindingForBuiltin String
        | NoSuchPrimitiveFunction String
        | ShadowedModule C.Name [A.ModuleName]
        | BuiltinInParameterisedModule String
        | IllegalLetInTelescope C.TypedBinding
        | NoRHSRequiresAbsurdPattern [NamedArg A.Pattern]
        | AbsurdPatternRequiresNoRHS [NamedArg A.Pattern]
        | TooFewFields QName [C.Name]
        | TooManyFields QName [C.Name]
        | DuplicateFields [C.Name]
        | DuplicateConstructors [C.Name]
        | UnexpectedWithPatterns [A.Pattern]
        | WithClausePatternMismatch A.Pattern Pattern
        | FieldOutsideRecord
        | ModuleArityMismatch A.ModuleName Telescope [NamedArg A.Expr]
    -- Coverage errors
    -- TODO: Remove some of the constructors in this section, now that
    -- the SplitError constructor has been added?
        | IncompletePatternMatching Term [Elim] -- can only happen if coverage checking is switched off
        | CoverageFailure QName [[Arg Pattern]]
        | UnreachableClauses QName [[Arg Pattern]]
        | CoverageCantSplitOn QName Telescope Args Args
        | CoverageCantSplitIrrelevantType Type
        | CoverageCantSplitType Type
        | WithoutKError Type Term Term
        | SplitError SplitError
    -- Positivity errors
        | NotStrictlyPositive QName [Occ]
    -- Import errors
        | LocalVsImportedModuleClash ModuleName
        | UnsolvedMetas [Range]
        | UnsolvedConstraints Constraints
        | SolvedButOpenHoles
          -- ^ Some interaction points (holes) have not be filled by user.
          --   There are not 'UnsolvedMetas' since unification solved them.
          --   This is an error, since interaction points are never filled
          --   without user interaction.
        | CyclicModuleDependency [C.TopLevelModuleName]
        | FileNotFound C.TopLevelModuleName [AbsolutePath]
        | OverlappingProjects AbsolutePath C.TopLevelModuleName C.TopLevelModuleName
        | AmbiguousTopLevelModuleName C.TopLevelModuleName [AbsolutePath]
        | ModuleNameDoesntMatchFileName C.TopLevelModuleName [AbsolutePath]
        | ClashingFileNamesFor ModuleName [AbsolutePath]
        | ModuleDefinedInOtherFile C.TopLevelModuleName AbsolutePath AbsolutePath
          -- ^ Module name, file from which it was loaded, file which
          -- the include path says contains the module.
    -- Scope errors
        | BothWithAndRHS
        | NotInScope [C.QName]
        | NoSuchModule C.QName
        | AmbiguousName C.QName [A.QName]
        | AmbiguousModule C.QName [A.ModuleName]
        | UninstantiatedModule C.QName
        | ClashingDefinition C.QName A.QName
        | ClashingModule A.ModuleName A.ModuleName
        | ClashingImport C.Name A.QName
        | ClashingModuleImport C.Name A.ModuleName
        | PatternShadowsConstructor A.Name A.QName
        | ModuleDoesntExport C.QName [C.ImportedName]
        | DuplicateImports C.QName [C.ImportedName]
        | InvalidPattern C.Pattern
        | RepeatedVariablesInPattern [C.Name]
    -- Concrete to Abstract errors
        | NotAModuleExpr C.Expr
            -- ^ The expr was used in the right hand side of an implicit module
            --   definition, but it wasn't of the form @m Delta@.
        | NotAnExpression C.Expr
        | NotAValidLetBinding D.NiceDeclaration
        | NothingAppliedToHiddenArg C.Expr
        | NothingAppliedToInstanceArg C.Expr
    -- Pattern synonym errors
        | BadArgumentsToPatternSynonym A.QName
        | TooFewArgumentsToPatternSynonym A.QName
        | UnusedVariableInPatternSynonym
    -- Operator errors
        | NoParseForApplication [C.Expr]
        | AmbiguousParseForApplication [C.Expr] [C.Expr]
        | NoParseForLHS LHSOrPatSyn C.Pattern
        | AmbiguousParseForLHS LHSOrPatSyn C.Pattern [C.Pattern]
{- UNUSED
        | NoParseForPatternSynonym C.Pattern
        | AmbiguousParseForPatternSynonym C.Pattern [C.Pattern]
-}
    -- Usage errors
    -- Implicit From Scope errors
        | IFSNoCandidateInScope Type
    -- Safe flag errors
        | SafeFlagPostulate C.Name
        | SafeFlagPragma [String]
        | SafeFlagNoTerminationCheck
        | SafeFlagNonTerminating
        | SafeFlagTerminating
        | SafeFlagPrimTrustMe
    -- Language option errors
        | NeedOptionCopatterns
          deriving (Typeable, Show)

-- | Distinguish error message when parsing lhs or pattern synonym, resp.
data LHSOrPatSyn = IsLHS | IsPatSyn deriving (Eq, Show)

-- instance Show TypeError where
--   show _ = "<TypeError>" -- TODO: more info?

instance Error TypeError where
    noMsg  = strMsg ""
    strMsg = GenericError

-- | Type-checking errors.

data TCErr = TypeError TCState (Closure TypeError)
           | Exception Range String
           | IOException Range E.IOException
           | PatternErr  TCState -- ^ for pattern violations
           {- AbortAssign TCState -- ^ used to abort assignment to meta when there are instantiations -- UNUSED -}
  deriving (Typeable)

instance Error TCErr where
    noMsg  = strMsg ""
    strMsg = Exception noRange . strMsg

instance Show TCErr where
    show (TypeError _ e) = show (envRange $ clEnv e) ++ ": " ++ show (clValue e)
    show (Exception r s) = show r ++ ": " ++ s
    show (IOException r e) = show r ++ ": " ++ show e
    show (PatternErr _)  = "Pattern violation (you shouldn't see this)"
    {- show (AbortAssign _) = "Abort assignment (you shouldn't see this)" -- UNUSED -}

instance HasRange TCErr where
    getRange (TypeError _ cl)  = envRange $ clEnv cl
    getRange (Exception r _)   = r
    getRange (IOException r _) = r
    getRange (PatternErr s)    = noRange
    {- getRange (AbortAssign s)   = noRange -- UNUSED -}

instance Exception TCErr

-----------------------------------------------------------------------------
-- * The reduce monad
-----------------------------------------------------------------------------

-- | Environment of the reduce monad.
data ReduceEnv = ReduceEnv
  { redEnv :: TCEnv    -- ^ Read only access to environment.
  , redSt  :: TCState  -- ^ Read only access to state (signature, metas...).
  }

mapRedEnv :: (TCEnv -> TCEnv) -> ReduceEnv -> ReduceEnv
mapRedEnv f s = s { redEnv = f (redEnv s) }

mapRedSt :: (TCState -> TCState) -> ReduceEnv -> ReduceEnv
mapRedSt f s = s { redSt = f (redSt s) }

mapRedEnvSt :: (TCEnv -> TCEnv) -> (TCState -> TCState) -> ReduceEnv
            -> ReduceEnv
mapRedEnvSt f g (ReduceEnv e s) = ReduceEnv (f e) (g s)

newtype ReduceM a = ReduceM { unReduceM :: Reader ReduceEnv a }
  deriving (Functor, Applicative, Monad)

runReduceM :: ReduceM a -> TCM a
runReduceM m = do
  e <- ask
  s <- get
  return $ runReader (unReduceM m) (ReduceEnv e s)

runReduceF :: (a -> ReduceM b) -> TCM (a -> b)
runReduceF f = do
  e <- ask
  s <- get
  return $ \x -> runReader (unReduceM (f x)) (ReduceEnv e s)

instance MonadReader TCEnv ReduceM where
  ask = redEnv <$> ReduceM ask
  local f = ReduceM . local (mapRedEnv f) . unReduceM

---------------------------------------------------------------------------
-- * Type checking monad transformer
---------------------------------------------------------------------------

newtype TCMT m a = TCM { unTCM :: IORef TCState -> TCEnv -> m a }

-- TODO: make dedicated MonadTCEnv and MonadTCState service classes

instance MonadIO m => MonadReader TCEnv (TCMT m) where
  ask = TCM $ \s e -> return e
  local f (TCM m) = TCM $ \s e -> m s (f e)

instance MonadIO m => MonadState TCState (TCMT m) where
  get   = TCM $ \s _ -> liftIO (readIORef s)
  put s = TCM $ \r _ -> liftIO (writeIORef r s)

type TCM = TCMT IO

class ( Applicative tcm, MonadIO tcm
      , MonadReader TCEnv tcm
      , MonadState TCState tcm
      ) => MonadTCM tcm where
    liftTCM :: TCM a -> tcm a

instance MonadError TCErr (TCMT IO) where
  throwError = liftIO . throwIO
  catchError m h = TCM $ \r e -> do
    oldState <- liftIO (readIORef r)
    unTCM m r e `E.catch` \err -> do
      -- Reset the state, but do not forget changes to the persistent
      -- component.
      liftIO $ do
        newState <- readIORef r
        writeIORef r $ oldState { stPersistent = stPersistent newState }
      unTCM (h err) r e

-- | Preserve the state of the failing computation.
catchError_ :: TCM a -> (TCErr -> TCM a) -> TCM a
catchError_ m h = TCM $ \r e ->
  unTCM m r e
  `E.catch` \err -> unTCM (h err) r e

{-# SPECIALIZE INLINE mapTCMT :: (forall a. IO a -> IO a) -> TCM a -> TCM a #-}
mapTCMT :: (forall a. m a -> n a) -> TCMT m a -> TCMT n a
mapTCMT f (TCM m) = TCM $ \s e -> f (m s e)

pureTCM :: MonadIO m => (TCState -> TCEnv -> a) -> TCMT m a
pureTCM f = TCM $ \r e -> do
  s <- liftIO $ readIORef r
  return (f s e)

{-# RULES "liftTCM/id" liftTCM = id #-}
instance MonadIO m => MonadTCM (TCMT m) where
    liftTCM = mapTCMT liftIO

instance MonadTCM tcm => MonadTCM (MaybeT tcm) where
  liftTCM = lift . liftTCM

instance (Error err, MonadTCM tcm) => MonadTCM (ExceptT err tcm) where
  liftTCM = lift . liftTCM

instance (Monoid w, MonadTCM tcm) => MonadTCM (WriterT w tcm) where
  liftTCM = lift . liftTCM

{- The following is not possible since MonadTCM needs to be a
-- MonadState TCState and a MonadReader TCEnv

instance (MonadTCM tcm) => MonadTCM (StateT s tcm) where
  liftTCM = lift . liftTCM

instance (MonadTCM tcm) => MonadTCM (ReaderT r tcm) where
  liftTCM = lift . liftTCM
-}

instance MonadTrans TCMT where
    lift m = TCM $ \_ _ -> m

-- We want a special monad implementation of fail.
instance MonadIO m => Monad (TCMT m) where
    return = returnTCMT
    (>>=)  = bindTCMT
    (>>)   = thenTCMT
    fail   = internalError

-- One goal of the definitions and pragmas below is to inline the
-- monad operations as much as possible. This doesn't seem to have a
-- large effect on the performance of the normal executable, but (at
-- least on one machine/configuration) it has a massive effect on the
-- performance of the profiling executable [1], and reduces the time
-- attributed to bind from over 90% to about 25%.
--
-- [1] When compiled with -auto-all and run with -p: roughly 750%
-- faster for one example.

returnTCMT :: MonadIO m => a -> TCMT m a
returnTCMT = \x -> TCM $ \_ _ -> return x
{-# INLINE returnTCMT #-}

bindTCMT :: MonadIO m => TCMT m a -> (a -> TCMT m b) -> TCMT m b
bindTCMT = \(TCM m) k -> TCM $ \r e -> m r e >>= \x -> unTCM (k x) r e
{-# INLINE bindTCMT #-}

thenTCMT :: MonadIO m => TCMT m a -> TCMT m b -> TCMT m b
thenTCMT = \(TCM m1) (TCM m2) -> TCM $ \r e -> m1 r e >> m2 r e
{-# INLINE thenTCMT #-}

instance MonadIO m => Functor (TCMT m) where
    fmap = fmapTCMT

fmapTCMT :: MonadIO m => (a -> b) -> TCMT m a -> TCMT m b
fmapTCMT = \f (TCM m) -> TCM $ \r e -> liftM f (m r e)
{-# INLINE fmapTCMT #-}

instance MonadIO m => Applicative (TCMT m) where
    pure  = returnTCMT
    (<*>) = apTCMT

apTCMT :: MonadIO m => TCMT m (a -> b) -> TCMT m a -> TCMT m b
apTCMT = \(TCM mf) (TCM m) -> TCM $ \r e -> ap (mf r e) (m r e)
{-# INLINE apTCMT #-}

instance MonadIO m => MonadIO (TCMT m) where
  liftIO m = TCM $ \s e ->
              do let r = envRange e
                 liftIO $ wrap r $ do
                 x <- m
                 x `seq` return x
    where
      wrap r m = failOnException handleException
               $ E.catch m (handleIOException r)

      handleIOException r e = throwIO $ IOException r e
      handleException   r s = throwIO $ Exception r s

patternViolation :: TCM a
patternViolation = do
    s <- get
    throwError $ PatternErr s

internalError :: MonadTCM tcm => String -> tcm a
internalError s = typeError $ InternalError s

{-# SPECIALIZE typeError :: TypeError -> TCM a #-}
typeError :: MonadTCM tcm => TypeError -> tcm a
typeError err = liftTCM $ throwError =<< typeError_ err

{-# SPECIALIZE typeError_ :: TypeError -> TCM TCErr #-}
typeError_ :: MonadTCM tcm => TypeError -> tcm TCErr
typeError_ err = liftTCM $ TypeError <$> get <*> buildClosure err

-- | Running the type checking monad (most general form).
{-# SPECIALIZE runTCM :: TCEnv -> TCState -> TCM a -> IO (a, TCState) #-}
runTCM :: MonadIO m => TCEnv -> TCState -> TCMT m a -> m (a, TCState)
runTCM e s m = do
  r <- liftIO $ newIORef s
  a <- unTCM m r e
  s <- liftIO $ readIORef r
  return (a, s)

-- | Running the type checking monad on toplevel (with initial state).
runTCMTop :: TCM a -> IO (Either TCErr a)
runTCMTop m = (Right <$> runTCMTop' m) `E.catch` (return . Left)

runTCMTop' :: MonadIO m => TCMT m a -> m a
runTCMTop' m = do
  r <- liftIO $ newIORef initState
  unTCM m r initEnv

-- | 'runSafeTCM' runs a safe 'TCM' action (a 'TCM' action which cannot fail)
--   in the initial environment.

runSafeTCM :: TCM a -> TCState -> IO (a, TCState)
runSafeTCM m st = runTCM initEnv st m `E.catch` (\ (e :: TCErr) -> __IMPOSSIBLE__)
-- runSafeTCM m st = either__IMPOSSIBLE__ return <$> do
--     -- Errors must be impossible.
--     runTCM $ do
--         put st
--         a <- m
--         st <- get
--         return (a, st)

-- | Runs the given computation in a separate thread, with /a copy/ of
-- the current state and environment.
--
-- Note that Agda sometimes uses actual, mutable state. If the
-- computation given to @forkTCM@ tries to /modify/ this state, then
-- bad things can happen, because accesses are not mutually exclusive.
-- The @forkTCM@ function has been added mainly to allow the thread to
-- /read/ (a snapshot of) the current state in a convenient way.
--
-- Note also that exceptions which are raised in the thread are not
-- propagated to the parent, so the thread should not do anything
-- important.

forkTCM :: TCM a -> TCM ()
forkTCM m = do
  s <- get
  e <- ask
  liftIO $ void $ C.forkIO $ void $ runTCM e s m


-- | Base name for extended lambda patterns
extendedLambdaName :: String
extendedLambdaName = ".extendedlambda"

-- | Name of absurdLambda definitions.
absurdLambdaName :: String
absurdLambdaName = ".absurdlambda"

-- | Check whether we have an definition from an absurd lambda.
isAbsurdLambdaName :: QName -> Bool
isAbsurdLambdaName = (absurdLambdaName ==) . prettyShow . qnameName
