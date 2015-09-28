{-# LANGUAGE CPP #-}
{-# LANGUAGE DoAndIfThenElse #-}
{-# LANGUAGE OverloadedStrings #-}
module LaTeXAndHTML.Tests where

import Test.Tasty
import Test.Tasty.Silver
import Test.Tasty.Silver.Advanced (readFileMaybe)
import Data.Char
import Data.Maybe
import System.Exit
import System.FilePath
import System.Process
import qualified System.Process.Text as PT
import qualified Data.Text as T
import System.IO.Temp
import Data.Text.Encoding
import qualified Data.ByteString as BS

#if __GLASGOW_HASKELL__ <= 708
import Control.Applicative ((<$>))
#endif

import Utils


type LaTeXProg = String

allLaTeXProgs :: [LaTeXProg]
allLaTeXProgs = ["pdflatex", "xelatex", "lualatex"]

testDir :: FilePath
testDir = "test" </> "LaTeXAndHTML" </> "succeed"

tests :: IO TestTree
tests = do
  inpFiles <- getAgdaFilesInDir testDir
  agdaBin  <- getAgdaBin
  return $ testGroup "LaTeXAndHTML"
    [ mkLaTeXOrHTMLTest k agdaBin f
    | f <- inpFiles
    , k <- HTML : if takeExtension f == ".lagda" then [LaTeX] else []
    ]

data LaTeXResult
  = AgdaFailed ProgramResult
  | LaTeXFailed LaTeXProg ProgramResult
  | Success T.Text -- ^ The resulting LaTeX or HTML file.

data Kind = LaTeX | HTML
  deriving Show

mkLaTeXOrHTMLTest
  :: Kind
  -> FilePath -- ^ Agda binary.
  -> FilePath -- ^ Input file.
  -> TestTree
mkLaTeXOrHTMLTest k agdaBin inp = do
  goldenVsAction testName goldenFile doRun printLaTeXResult
  where
  extension = case k of
    LaTeX -> "tex"
    HTML  -> "html"

  flag = case k of
    LaTeX -> "latex"
    HTML  -> "html"

  testName    = dropExtension (takeFileName inp) ++ "_" ++ show k
  goldenFile  = (dropExtension inp) <.> extension
  compFile    = (dropExtension inp) <.> ".compile"
  outFileName = takeFileName goldenFile

  doRun = withTempDirectory "." testName $ \outDir -> do
    let agdaArgs = [ "--" ++ flag
                   , "-i" ++ testDir
                   , inp
                   , "--ignore-interfaces"
                   , "--" ++ flag ++ "-dir=" ++ outDir
                   ]
    res@(ret, _, _) <- PT.readProcessWithExitCode agdaBin agdaArgs T.empty
    if ret /= ExitSuccess then
      return $ AgdaFailed res
    else do
      output <- decodeUtf8 <$> BS.readFile (outDir </> outFileName)
      let done = return $ Success output
      case k of
        HTML  -> done
        LaTeX -> do
          -- read compile options
          doCompile <- readFileMaybe compFile
          case doCompile of
            -- there is no compile file, so we are finished
            Nothing -> done
            -- there is a compile file, check it's content
            Just content -> do
              let latexProgs =
                    fromMaybe allLaTeXProgs
                      (readMaybe $ T.unpack $ decodeUtf8 content)
              -- run all latex compilers
              foldl (runLaTeX outFileName outDir) done latexProgs

  runLaTeX :: FilePath -- tex file
      -> FilePath -- working dir
      -> (IO LaTeXResult) -- continuation
      -> LaTeXProg
      -> IO LaTeXResult
  runLaTeX texFile wd cont prog = do
      let proc' = (proc prog ["-interaction=batchmode", texFile]) { cwd = Just wd }
#if MIN_VERSION_process_extras(0,3,0)
      res@(ret, _, _) <- PT.readCreateProcessWithExitCode proc' T.empty
#else
      (_, _, _, pHandle) <- createProcess proc'
      ret <- waitForProcess pHandle
      let res = (ret, T.empty, T.empty)
#endif
      if ret == ExitSuccess then
        cont
      else
        return $ LaTeXFailed prog res

printLaTeXResult :: LaTeXResult -> T.Text
printLaTeXResult (Success t) = t
printLaTeXResult (AgdaFailed p)= "AGDA_COMPILE_FAILED\n\n" `T.append` printProcResult p
printLaTeXResult (LaTeXFailed prog p) = "LATEX_COMPILE_FAILED with "
    `T.append` (T.pack prog)
    `T.append` "\n\n"
    `T.append` printProcResult p

readMaybe :: Read a => String -> Maybe a
readMaybe s =
  case reads s of
    [(x, rest)] | all isSpace rest -> Just x
    _                              -> Nothing
