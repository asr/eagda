{-# LANGUAGE TupleSections #-}
module Agda.Interaction.Library
  ( getDefaultLibraries
  , getInstalledLibraries
  , libraryIncludePaths
  , LibName
  , LibM
  ) where

import Control.Arrow (first, second)
import Control.Applicative
import Control.Exception
import Control.Monad.Writer
import Data.Char
import Data.Either
import Data.Function
import Data.List
import Data.Maybe
import System.Directory
import System.FilePath
import System.Environment

import Agda.Interaction.Library.Base
import Agda.Interaction.Library.Parse
import Agda.Utils.Monad
import Agda.Utils.Environment
import Agda.Utils.Except ( ExceptT, runExceptT, MonadError(throwError) )
import Agda.Utils.List
import Agda.Utils.Pretty

type LibM = ExceptT Doc IO

catchIO :: IO a -> (IOException -> IO a) -> IO a
catchIO = catch

getAgdaAppDir :: IO FilePath
getAgdaAppDir = do
  agdaDir <- lookupEnv "AGDA_DIR"
  case agdaDir of
    Nothing  -> getAppUserDataDirectory "agda"
    Just dir ->
      ifM (doesDirectoryExist dir) (canonicalizePath dir) $ do
        d <- getAppUserDataDirectory "agda"
        putStrLn $ "Warning: Environment variable AGDA_DIR points to non-existing directory " ++ show dir ++ ", using " ++ show d ++ " instead."
        return d

libraryFile :: FilePath
libraryFile = "libraries"

defaultsFile :: FilePath
defaultsFile = "defaults"

data LibError = LibNotFound FilePath LibName
              | AmbiguousLib LibName [AgdaLibFile]
              | OtherError String
  deriving (Show)

mkLibM :: [AgdaLibFile] -> IO (a, [LibError]) -> LibM a
mkLibM libs m = do
  (x, err) <- lift m
  case err of
    [] -> return x
    _  -> throwError =<< lift (vcat <$> mapM (formatLibError libs) err)

findAgdaLibFiles :: FilePath -> IO [FilePath]
findAgdaLibFiles root = do
  libs <- map (root </>) . filter ((== ".agda-lib") . takeExtension) <$> getDirectoryContents root
  case libs of
    []    -> do
      up <- canonicalizePath $ root </> ".."
      if up == root then return [] else findAgdaLibFiles up
    files -> return files

getDefaultLibraries :: FilePath -> LibM ([LibName], [FilePath])
getDefaultLibraries root = mkLibM [] $ do
  libs <- findAgdaLibFiles root
  if null libs then first (, []) <$> readDefaultsFile
    else first libsAndPaths <$> parseLibFiles libs
  where
    libsAndPaths ls = (concatMap libDepends ls, concatMap libIncludes ls)

readDefaultsFile :: IO ([LibName], [LibError])
readDefaultsFile = do
    agdaDir <- getAgdaAppDir
    let file = agdaDir </> defaultsFile
    ifM (doesFileExist file) (do
      ls <- stripCommentLines <$> readFile file
      return ("." : concatMap splitCommas ls, [])
      ) {- else -} (return (["."], []))
  `catchIO` \e -> return (["."], [OtherError $ "Failed to read defaults file.\n" ++ show e])

getLibrariesFile :: Maybe FilePath -> IO FilePath
getLibrariesFile overrideLibFile = do
  agdaDir <- getAgdaAppDir
  return $ fromMaybe (agdaDir </> libraryFile) overrideLibFile

getInstalledLibraries :: Maybe FilePath -> LibM [AgdaLibFile]
getInstalledLibraries overrideLibFile = mkLibM [] $ do
    file <- getLibrariesFile overrideLibFile
    ifM (doesFileExist file) (do
      files <- mapM expandEnvironmentVariables =<< stripCommentLines <$> readFile file
      parseLibFiles files
      ) {- else -} (return ([], []))
  `catchIO` \e -> return ([], [OtherError $ "Failed to read installed libraries.\n" ++ show e])

parseLibFiles :: [FilePath] -> IO ([AgdaLibFile], [LibError])
parseLibFiles files = do
  rs <- mapM parseLibFile files
  let errs = [ OtherError $ path ++ ":" ++ (if all isDigit (take 1 err) then "" else " ") ++ err
             | (path, Left err) <- zip files rs ]
  return (rights rs, errs)

stripCommentLines :: String -> [String]
stripCommentLines = concatMap strip . lines
  where
    strip s = [ s' | not $ null s' ]
      where s' = stripComments $ dropWhile isSpace s

formatLibError :: [AgdaLibFile] -> LibError -> IO Doc
formatLibError installed (LibNotFound file lib) = do
  return $ vcat $
    [ text $ "Library '" ++ lib ++ "' not found."
    , sep [ text "Add the path to its .agda-lib file to"
          , nest 2 $ text $ "'" ++ file ++ "'"
          , text "to install." ]
    , text "Installed libraries:"
    ] ++
    map (nest 2)
      (if null installed then [text "(none)"]
      else [ sep [ text $ libName l, nest 2 $ parens $ text $ libFile l ] | l <- installed ])
formatLibError _ (AmbiguousLib lib tgts) = return $
  vcat $ sep [ text $ "Ambiguous library '" ++ lib ++ "'."
             , text "Could refer to any one of" ]
       : [ nest 2 $ text (libName l) <+> parens (text $ libFile l) | l <- tgts ]
formatLibError _ (OtherError err) = return $ text err

libraryIncludePaths :: Maybe FilePath -> [AgdaLibFile] -> [LibName] -> LibM [FilePath]
libraryIncludePaths overrideLibFile libs xs0 = mkLibM libs $ do
    file <- getLibrariesFile overrideLibFile
    return $ runWriter ((dot ++) . incs <$> find file [] xs)
  where
    xs = map trim $ delete "." xs0
    trim = reverse . dropWhile isSpace . reverse . dropWhile isSpace
    incs = nub . concatMap libIncludes
    dot = [ "." | elem "." xs0 ]

    find :: FilePath -> [LibName] -> [LibName] -> Writer [LibError] [AgdaLibFile]
    find _ _ [] = pure []
    find file visited (x : xs)
      | elem x visited = find file visited xs
      | otherwise =
          case findLib x libs of
            [l] -> (l :) <$> find file (x : visited) (libDepends l ++ xs)
            []  -> tell [LibNotFound file x] >> find file (x : visited) xs
            ls  -> tell [AmbiguousLib x ls] >> find file (x : visited) xs

findLib :: LibName -> [AgdaLibFile] -> [AgdaLibFile]
findLib x libs =
  case ls of
    l : ls -> l : takeWhile ((== versionMeasure l) . versionMeasure) ls
    []     -> []
  where
    ls = sortBy (flip compare `on` versionMeasure) [ l | l <- libs, matchLib x l ]

    -- foo > foo-2.2 > foo-2.0.1 > foo-2 > foo-1.0
    versionMeasure l = (rx, null vs, vs)
      where
        (rx, vs) = versionView (libName l)

matchLib :: LibName -> AgdaLibFile -> Bool
matchLib x l = rx == ry && (vx == vy || null vx)
  where
    (rx, vx) = versionView x
    (ry, vy) = versionView $ libName l

-- versionView "foo-1.2.3" == ("foo", [1, 2, 3])
versionView :: LibName -> (LibName, [Int])
versionView s =
  case span (\ c -> isDigit c || c == '.') (reverse s) of
    (v, '-' : x) | valid vs -> (reverse x, reverse $ map (read . reverse) vs)
      where vs = chopWhen (== '.') v
            valid [] = False
            valid vs = not $ any null vs
    _ -> (s, [])

