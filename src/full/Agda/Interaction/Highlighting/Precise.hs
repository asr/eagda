{-# LANGUAGE DeriveDataTypeable #-}

-- | Types used for precise syntax highlighting.

module Agda.Interaction.Highlighting.Precise
  ( -- * Files
    Aspect(..)
  , NameKind(..)
  , OtherAspect(..)
  , Aspects(..)
  , File
  , HighlightingInfo
    -- ** Creation
  , singleton
  , several
    -- ** Inspection
  , smallestPos
  , toMap
    -- * Compressed files
  , CompressedFile(..)
  , compressedFileInvariant
  , compress
  , decompress
  , noHighlightingInRange
    -- ** Creation
  , singletonC
  , severalC
  , splitAtC
    -- ** Inspection
  , smallestPosC
    -- * Tests
  , Agda.Interaction.Highlighting.Precise.tests
  ) where

import Agda.Utils.TestHelpers
import Agda.Utils.String
import Agda.Utils.List hiding (tests)
import Data.List
import Data.Function
import Data.Monoid
import Control.Applicative ((<$>), (<*>))
import Control.Monad
import Agda.Utils.QuickCheck
import Data.IntMap (IntMap)
import qualified Data.IntMap as IntMap
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Typeable (Typeable)

import qualified Agda.Syntax.Common as C
import qualified Agda.Syntax.Concrete as SC

import Agda.Interaction.Highlighting.Range

------------------------------------------------------------------------
-- Files

-- | Syntactic aspects of the code. (These cannot overlap.)
--   They can be obtained from the lexed tokens already,
--   except for the 'NameKind'.

data Aspect
  = Comment
  | Keyword
  | String
  | Number
  | Symbol                     -- ^ Symbols like forall, =, ->, etc.
  | PrimitiveType              -- ^ Things like Set and Prop.
  | Name (Maybe NameKind) Bool -- ^ Is the name an operator part?
    deriving (Eq, Show, Typeable)

-- | @NameKind@s are figured our during scope checking.

data NameKind
  = Bound                   -- ^ Bound variable.
  | Constructor C.Induction -- ^ Inductive or coinductive constructor.
  | Datatype
  | Field                   -- ^ Record field.
  | Function
  | Module                  -- ^ Module name.
  | Postulate
  | Primitive               -- ^ Primitive.
  | Record                  -- ^ Record type.
  | Argument                -- ^ Named argument, like x in {x = v}
    deriving (Eq, Show, Typeable)

-- | Other aspects, generated by type checking.
--   (These can overlap with each other and with 'Aspect's.)

data OtherAspect
  = Error
  | DottedPattern
  | UnsolvedMeta
  | UnsolvedConstraint
    -- ^ Unsolved constraint not connected to meta-variable. This
    -- could for instance be an emptyness constraint.
  | TerminationProblem
  | IncompletePattern
    -- ^ When this constructor is used it is probably a good idea to
    -- include a 'note' explaining why the pattern is incomplete.
  | TypeChecks
    -- ^ Code which is being type-checked.
    deriving (Eq, Show, Enum, Bounded, Typeable)

-- | Meta information which can be associated with a
-- character\/character range.

data Aspects = Aspects
  { aspect       :: Maybe Aspect
  , otherAspects :: [OtherAspect]
  , note         :: Maybe String
    -- ^ This note, if present, can be displayed as a tool-tip or
    -- something like that. It should contain useful information about
    -- the range (like the module containing a certain identifier, or
    -- the fixity of an operator).
  , definitionSite :: Maybe (SC.TopLevelModuleName, Int)
    -- ^ The definition site of the annotated thing, if applicable and
    --   known. File positions are counted from 1.
  }
  deriving (Eq, Show, Typeable)

-- | A 'File' is a mapping from file positions to meta information.
--
-- The first position in the file has number 1.

newtype File = File { mapping :: IntMap Aspects }
  deriving (Eq, Show, Typeable)

-- | Syntax highlighting information.

type HighlightingInfo = CompressedFile

------------------------------------------------------------------------
-- Creation

-- | @'singleton' rs m@ is a file whose positions are those in @rs@,
-- and in which every position is associated with @m@.

singleton :: Ranges -> Aspects -> File
singleton rs m = File {
 mapping = IntMap.fromAscList [ (p, m) | p <- rangesToPositions rs ] }

-- | Like 'singleton', but with several 'Ranges' instead of only one.

several :: [Ranges] -> Aspects -> File
several rs m = mconcat $ map (\r -> singleton r m) rs

------------------------------------------------------------------------
-- Merging

-- | Merges meta information.

mergeAspects :: Aspects -> Aspects -> Aspects
mergeAspects m1 m2 = Aspects
  { aspect       = (mplus `on` aspect) m1 m2
  , otherAspects = nub $ ((++) `on` otherAspects) m1 m2
  , note         = case (note m1, note m2) of
      (Just n1, Just n2) -> Just $
         if n1 == n2
           then n1
           else addFinalNewLine n1 ++ "----\n" ++ n2
      (Just n1, Nothing) -> Just n1
      (Nothing, Just n2) -> Just n2
      (Nothing, Nothing) -> Nothing
  , definitionSite = (mplus `on` definitionSite) m1 m2
  }

instance Monoid Aspects where
  mempty = Aspects
    { aspect         = Nothing
    , otherAspects   = []
    , note           = Nothing
    , definitionSite = Nothing
    }
  mappend = mergeAspects

-- | Merges files.

merge :: File -> File -> File
merge f1 f2 =
  File { mapping = (IntMap.unionWith mappend `on` mapping) f1 f2 }

instance Monoid File where
  mempty  = File { mapping = IntMap.empty }
  mappend = merge

------------------------------------------------------------------------
-- Inspection

-- | Returns the smallest position, if any, in the 'File'.

smallestPos :: File -> Maybe Int
smallestPos = fmap (fst . fst) . IntMap.minViewWithKey . mapping

-- | Convert the 'File' to a map from file positions (counting from 1)
-- to meta information.

toMap :: File -> IntMap Aspects
toMap = mapping

------------------------------------------------------------------------
-- Compressed files

-- | A compressed 'File', in which consecutive positions with the same
-- 'Aspects' are stored together.

newtype CompressedFile =
  CompressedFile { ranges :: [(Range, Aspects)] }
  deriving (Eq, Show, Typeable)

-- | Invariant for compressed files.
--
-- Note that these files are not required to be /maximally/
-- compressed, because ranges are allowed to be empty, and the
-- 'Aspects's in adjacent ranges are allowed to be equal.

compressedFileInvariant :: CompressedFile -> Bool
compressedFileInvariant (CompressedFile []) = True
compressedFileInvariant (CompressedFile f)  =
  all rangeInvariant rs &&
  all (not . empty) rs &&
  and (zipWith (<=) (map to $ init rs) (map from $ tail rs))
  where rs = map fst f

-- | Compresses a file by merging consecutive positions with equal
-- meta information into longer ranges.

compress :: File -> CompressedFile
compress f =
  CompressedFile $ map join $ groupBy' p (IntMap.toAscList $ mapping f)
  where
  p (pos1, m1) (pos2, m2) = pos2 == pos1 + 1 && m1 == m2
  join pms = ( Range { from = head ps, to = last ps + 1 }
             , head ms
             )
    where (ps, ms) = unzip pms

-- | Decompresses a compressed file.

decompress :: CompressedFile -> File
decompress =
  File .
  IntMap.fromList .
  concat .
  map (\(r, m) -> [ (p, m) | p <- rangeToPositions r ]) .
  ranges

prop_compress f =
  compressedFileInvariant c
  &&
  decompress c == f
  where c = compress f

-- | Clear any highlighting info for the given ranges. Used to make sure
--   unsolved meta highlighting overrides error highlighting.
noHighlightingInRange :: Ranges -> CompressedFile -> CompressedFile
noHighlightingInRange rs (CompressedFile hs) =
    CompressedFile $ concatMap clear hs
  where
    clear (r, i) =
      case minus (Ranges [r]) rs of
        Ranges [] -> []
        Ranges rs -> [ (r, i) | r <- rs ]

------------------------------------------------------------------------
-- Operations that work directly with compressed files

-- | @'singletonC' rs m@ is a file whose positions are those in @rs@,
-- and in which every position is associated with @m@.

singletonC :: Ranges -> Aspects -> CompressedFile
singletonC (Ranges rs) m =
  CompressedFile [(r, m) | r <- rs, not (empty r)]

prop_singleton rs m = singleton rs m == decompress (singletonC rs m)

-- | Like 'singletonR', but with a list of 'Ranges' instead of a
-- single one.

severalC :: [Ranges] -> Aspects -> CompressedFile
severalC rss m = mconcat $ map (\rs -> singletonC rs m) rss

prop_several rss m = several rss m == decompress (severalC rss m)

-- | Merges compressed files.

mergeC :: CompressedFile -> CompressedFile -> CompressedFile
mergeC (CompressedFile f1) (CompressedFile f2) =
  CompressedFile (mrg f1 f2)
  where
  mrg []             f2             = f2
  mrg f1             []             = f1
  mrg (p1@(i1,_):f1) (p2@(i2,_):f2)
    | to i1 <= from i2 = p1 : mrg f1      (p2:f2)
    | to i2 <= from i1 = p2 : mrg (p1:f1) f2
    | to i1 <= to i2   = ps1 ++ mrg f1 (ps2 ++ f2)
    | otherwise        = ps1 ++ mrg (ps2 ++ f1) f2
      where (ps1, ps2) = fuse p1 p2

  -- Precondition: The ranges are overlapping.
  fuse (i1, m1) (i2, m2) =
    ( fix [ (Range { from = a, to = b }, ma)
          , (Range { from = b, to = c }, mergeAspects m1 m2)
          ]
    , fix [ (Range { from = c, to = d }, md)
          ]
    )
    where
    [(a, ma), (b, _), (c, _), (d, md)] =
      sortBy (compare `on` fst)
             [(from i1, m1), (to i1, m1), (from i2, m2), (to i2, m2)]
    fix = filter (not . empty . fst)

prop_merge f1 f2 =
  merge f1 f2 == decompress (mergeC (compress f1) (compress f2))

instance Monoid CompressedFile where
  mempty  = CompressedFile []
  mappend = mergeC

-- | @splitAtC p f@ splits the compressed file @f@ into @(f1, f2)@,
-- where all the positions in @f1@ are @< p@, and all the positions
-- in @f2@ are @>= p@.

splitAtC :: Int -> CompressedFile ->
            (CompressedFile, CompressedFile)
splitAtC p f = (CompressedFile f1, CompressedFile f2)
  where
  (f1, f2) = split $ ranges f

  split [] = ([], [])
  split (rx@(r,x) : f)
    | p <= from r = ([], rx:f)
    | to r <= p   = (rx:f1, f2)
    | otherwise   = ([ (toP, x) ], (fromP, x) : f)
    where (f1, f2) = split f
          toP      = Range { from = from r, to = p    }
          fromP    = Range { from = p,      to = to r }

prop_splitAtC p f =
  all (<  p) (positions f1) &&
  all (>= p) (positions f2) &&
  decompress (mergeC f1 f2) == decompress f
  where
  (f1, f2) = splitAtC p f

  positions = IntMap.keys . toMap . decompress

-- | Returns the smallest position, if any, in the 'CompressedFile'.

smallestPosC :: CompressedFile -> Maybe Int
smallestPosC (CompressedFile [])           = Nothing
smallestPosC (CompressedFile ((r, _) : _)) = Just (from r)

prop_smallestPos f = smallestPos (decompress f) == smallestPosC f

------------------------------------------------------------------------
-- Generators

instance Arbitrary Aspect where
  arbitrary =
    frequency [ (3, elements [ Comment, Keyword, String, Number
                             , Symbol, PrimitiveType ])
              , (1, liftM2 Name (maybeGen arbitrary) arbitrary)
              ]

  shrink Name{} = [Comment]
  shrink _      = []

instance CoArbitrary Aspect where
  coarbitrary Comment       = variant 0
  coarbitrary Keyword       = variant 1
  coarbitrary String        = variant 2
  coarbitrary Number        = variant 3
  coarbitrary Symbol        = variant 4
  coarbitrary PrimitiveType = variant 5
  coarbitrary (Name nk b)   =
    variant 6 . maybeCoGen coarbitrary nk . coarbitrary b

instance Arbitrary NameKind where
  arbitrary = oneof $ [liftM Constructor arbitrary] ++
                      map return [ Bound
                                 , Datatype
                                 , Field
                                 , Function
                                 , Module
                                 , Postulate
                                 , Primitive
                                 , Record
                                 ]

  shrink Constructor{} = [Bound]
  shrink _             = []

instance CoArbitrary NameKind where
  coarbitrary Bound             = variant 0
  coarbitrary (Constructor ind) = variant 1 . coarbitrary ind
  coarbitrary Datatype          = variant 2
  coarbitrary Field             = variant 3
  coarbitrary Function          = variant 4
  coarbitrary Module            = variant 5
  coarbitrary Postulate         = variant 6
  coarbitrary Primitive         = variant 7
  coarbitrary Record            = variant 8
  coarbitrary Argument          = variant 9

instance Arbitrary OtherAspect where
  arbitrary = elements [minBound .. maxBound]

instance CoArbitrary OtherAspect where
  coarbitrary = coarbitrary . fromEnum

instance Arbitrary Aspects where
  arbitrary = do
    aspect  <- arbitrary
    other   <- arbitrary
    note    <- maybeGen string
    defSite <- arbitrary
    return (Aspects { aspect = aspect, otherAspects = other
                     , note = note, definitionSite = defSite })
    where string = listOfElements "abcdefABCDEF/\\.\"'@()åäö\n"

  shrink (Aspects a o n d) =
    [ Aspects a o n d | a <- shrink a ] ++
    [ Aspects a o n d | o <- shrink o ] ++
    [ Aspects a o n d | n <- shrink n ] ++
    [ Aspects a o n d | d <- shrink d ]

instance CoArbitrary Aspects where
  coarbitrary (Aspects aspect otherAspects note defSite) =
    coarbitrary aspect .
    coarbitrary otherAspects .
    coarbitrary note .
    coarbitrary defSite

instance Arbitrary File where
  arbitrary = fmap (File . IntMap.fromList) $ listOf arbitrary
  shrink    = map (File . IntMap.fromList) . shrink . IntMap.toList . toMap

instance CoArbitrary File where
  coarbitrary (File rs) = coarbitrary (IntMap.toAscList rs)

instance Arbitrary CompressedFile where
  arbitrary = do
    rs <- (\ns1 ns2 -> toRanges $ sort $
                         ns1 ++ concatMap (\n -> [n, succ n]) ns2) <$>
            arbitrary <*> arbitrary
    CompressedFile <$> mapM (\r -> (,) r <$> arbitrary) rs
    where
    toRanges (f : t : rs)
      | f == t    = toRanges (t : rs)
      | otherwise = Range { from = f, to = t } :
                    toRanges (case rs of
                                f : rs | t == f -> rs
                                _               -> rs)
    toRanges _ = []

  shrink (CompressedFile f) = CompressedFile <$> shrink f

------------------------------------------------------------------------
-- All tests

-- | All the properties.

tests :: IO Bool
tests = runTests "Agda.Interaction.Highlighting.Precise"
  [ quickCheck' compressedFileInvariant
  , quickCheck' (all compressedFileInvariant . shrink)
  , quickCheck' (\r m -> compressedFileInvariant $ singletonC r m)
  , quickCheck' (\rs m -> compressedFileInvariant $ severalC rs m)
  , quickCheck' (\f1 f2 -> compressedFileInvariant $ mergeC f1 f2)
  , quickCheck' (\i f -> all compressedFileInvariant $
                         (\(f1, f2) -> [f1, f2]) $
                         splitAtC i f)
  , quickCheck' prop_compress
  , quickCheck' prop_singleton
  , quickCheck' prop_several
  , quickCheck' prop_merge
  , quickCheck' prop_splitAtC
  , quickCheck' prop_smallestPos
  ]
