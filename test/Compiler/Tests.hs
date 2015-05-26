-- GHC 7.4.2 requires this layout for the pragmas. See Issue 1460.
{-# LANGUAGE CPP,
             DoAndIfThenElse,
             FlexibleInstances,
             OverloadedStrings,
             TypeSynonymInstances,
             PatternGuards #-}

module Compiler.Tests where

import Test.Tasty
import Test.Tasty.Silver.Advanced (readFileMaybe)
import Test.Tasty.Silver
import Test.Tasty.Silver.Filter
import qualified Data.Text as T
import Data.Text.Encoding
import System.IO.Temp
import System.FilePath
import System.Exit
import System.Process.Text as PT
#if MIN_VERSION_process(1,2,3)
import System.Process (callProcess, proc, readCreateProcess, CreateProcess (..))
#else
import System.Process (callProcess, proc, createProcess, waitForProcess, CreateProcess (..))
#endif


#if __GLASGOW_HASKELL__ <= 708
import Control.Applicative ((<$>))
#endif

import System.Environment
import Data.Maybe
import Data.Char
import qualified Data.Set as S
import System.Directory

type ProgramResult = (ExitCode, T.Text, T.Text)
type AgdaArgs = [String]
type GHCArgs = [String]

data ExecResult
  = CompileFailed
    { result :: ProgramResult }
  | CompileSucceeded
  | ExecutedProg
    { result :: ProgramResult }
  deriving (Show, Read, Eq)

data Compiler = MAlonzo | UHC
  deriving (Show, Read, Eq)

enabledCompilers :: [Compiler]
enabledCompilers = [ MAlonzo, UHC ]

data CompilerOptions
  = CompilerOptions
    { extraAgdaArgs :: AgdaArgs
    } deriving (Show, Read)

data TestOptions
  = TestOptions
    { forCompilers :: [(Compiler, CompilerOptions)]
    , executeProg :: Bool
    } deriving (Show, Read)

defaultOptions :: TestOptions
defaultOptions = TestOptions
  { forCompilers = [ (c, co) | c <- enabledCompilers ]
  , executeProg = True
  }
  where co = CompilerOptions []


disabledTests :: [RegexFilter]
disabledTests =
-- The Compiler tests using the standard library are horribly
-- slow at the moment (1min or more per test case).
-- Disable them by default for now.
  [ RFInclude "Compiler/.*/with-stdlib"
-- See issue 1414
  , RFInclude "Compiler/MAlonzo/simple/FlexibleInterpreter"
-- Disable UHC backend tests if the backend is also disabled.
#if !defined(UHC_BACKEND)
  , RFInclude "Compiler/UHC/"
#endif
  ]

tests :: IO TestTree
tests = do
  ts <- mapM forComp enabledCompilers
  return $ testGroup "Compiler" ts
  where forComp comp = testGroup (show comp) . catMaybes
            <$> sequence
                [ Just <$> simpleTests comp
                , Just <$> stdlibTests comp
                , specialTests comp]


getAgdaBin :: IO FilePath
getAgdaBin = do
  agda <- getProg1 "AGDA_BIN"
  case agda of
    Just x -> return x
    Nothing -> fail "AGDA_BIN environment variable not set, aborting..."

-- | Gets the program executable. If an environment variable
-- YYY_BIN is defined (with yyy converted to upper case),
-- the value of it is returned. Otherwise, the input value
-- is returned unchanged.
getProg :: String -> IO FilePath
getProg prog = fromMaybe prog <$> getProg1 (map toUpper prog ++ "_BIN")

getProg1 :: String -> IO (Maybe FilePath)
getProg1 prog = do
  env' <- getEnvironment
  case lookup prog env' of
      Nothing -> return Nothing
      (Just x) -> return $ Just x

agdaExts :: S.Set String
agdaExts = S.fromList [".agda", ".lagda"]

getAgdaFilesInDir :: String -> IO [FilePath]
getAgdaFilesInDir dir = map (dir </>) . filter (flip S.member agdaExts . takeExtension) <$> getDirectoryContents dir

simpleTests :: Compiler -> IO TestTree
simpleTests comp = do
  agdaBin <- getAgdaBin
  let testDir = "test" </> "Compiler" </> "simple"
  inps <- getAgdaFilesInDir testDir

  withSetup setup agdaBin inps testDir ["-i" ++ testDir, "-itest/"] comp "simple"
  where setup :: Compiler -> (IO (IO AgdaArgs -> TestTree)) -> IO TestTree
        setup UHC tree = tree >>= \t -> return $ t $ return []
        setup MAlonzo tree = withGhcLibs ["test/"] <$> tree

stdlibTests :: Compiler -> IO TestTree
stdlibTests comp = do
  agdaBin <- getAgdaBin
  let testDir = "test" </> "Compiler" </> "with-stdlib"
  inps <- getAgdaFilesInDir testDir

  withSetup setup agdaBin inps testDir ["-i" ++ testDir, "-i" ++ "std-lib" </> "src"] comp "with-stdlib"
  where setup :: Compiler -> (IO (IO AgdaArgs -> TestTree)) -> IO TestTree
        setup UHC tree = tree >>= \t -> return $ t $ return []
        setup MAlonzo tree = withGhcLibs ["std-lib/ffi/"] <$> tree


specialTests :: Compiler -> IO (Maybe TestTree)
specialTests MAlonzo = do
  agdaBin <- getAgdaBin
  let t = withGhcLibs ["test/"] $ (\args -> fromJust $
            agdaRunProgGoldenTest1 agdaBin testDir MAlonzo ((extraArgs ++) . ghcArgsAsAgdaArgs <$> args)
                        (testDir </> "ExportTestAgda.agda") defaultOptions (cont args)
            )

  return $ Just $ testGroup "special" [t]
  where extraArgs = ["-i" ++ testDir, "-itest/", "--no-main"]
        testDir = "test" </> "Compiler" </> "special"
        cont args compDir = do
            args' <- args
            (ret, sout, _) <- PT.readProcessWithExitCode "runghc"
                    (args' ++ [ "-i" ++ compDir
                     , testDir </> "ExportTest.hs"
                     ])
                    T.empty
            -- ignore stderr, as there may be some GHC warnings in it
            return $ ExecutedProg (ret, sout, T.empty)
specialTests UHC = return Nothing

withSetup :: (Compiler -> (IO (IO AgdaArgs -> TestTree)) -> IO TestTree) -- setup function
    -> FilePath -- Agda executable
    -> [FilePath] -- inputs
    -> FilePath -- test directory
    -> AgdaArgs -- extra agda arguments
    -> Compiler
    -> TestName -- test group name
    -> IO TestTree
withSetup setup agdaBin inps testDir extraArgs comp  testGrpNm = do
  setup comp (do
    mkTests' <- mapM mkTest inps
    return (\args ->
        testGroup testGrpNm $ catMaybes $ map ($ args) mkTests'
      )
    )
  where mkTest :: FilePath -> IO (IO AgdaArgs -> Maybe TestTree)
        mkTest = (\inp -> do
          opts <- readOptions inp
          return (\args ->
            agdaRunProgGoldenTest agdaBin testDir comp ((extraArgs  ++) . ghcArgsAsAgdaArgs <$> args) inp opts
            )
          )



-- Sets up a temporary package db and installs the given packages there.
withGhcLibs :: [String] -- ^ path to the package directories to install.
    -> (IO (GHCArgs) -> TestTree)
    -> TestTree
withGhcLibs pkgDirs mkTree =
  withResource createPkgDb rmPkgDb (\si -> mkTree (mkArgs <$> si))
  where rmPkgDb = removeDirectoryRecursive . fst
        createPkgDb = (do
          pwd <- getCurrentDirectory
          tempDir <- createTempDirectory pwd "exec-test-pkgs"
          let pkgDb = tempDir </> "pkgdb"
          callProcess "ghc-pkg" ["init", pkgDb]
          mapM_ (installPkg tempDir pkgDb) pkgDirs
          return (tempDir, pkgDb)
          )
        installPkg :: FilePath -> FilePath -> FilePath -> IO ()
        installPkg tempDir pkgDb pkgDir = do
          pwd <- getCurrentDirectory
          withTempDirectory pwd "pkg-build" $ \builddir -> (do
            callProcess1 pkgDir "runhaskell" ["Setup.hs", "configure", "--builddir=" ++ builddir
                                             , "--prefix=" ++ tempDir, "--package-db=" ++ pkgDb]
            callProcess1 pkgDir "runhaskell" ["Setup.hs", "build", "--builddir=" ++ builddir]
            callProcess1 pkgDir "runhaskell" ["Setup.hs", "install", "--builddir=" ++ builddir]
            )
        mkArgs :: (FilePath, FilePath) -> AgdaArgs
#if __GLASGOW_HASKELL__ > 704
        mkArgs (_, pkgDb) = ["-no-user-package-db",   "-package-db=" ++ pkgDb]
#else
        mkArgs (_, pkgDb) = ["-no-user-package-conf", "-package-conf=" ++ pkgDb]
#endif
        callProcess1 :: FilePath -> FilePath -> [String] -> IO ()
#if MIN_VERSION_process(1,2,3)
        callProcess1 wd cmd args = readCreateProcess ((proc cmd args) {cwd = Just wd}) "" >> return ()
#else
        -- trying to use process 1.2.3.0 with GHC 7.4 leads to cabal hell,
        -- so we really want to support older versions of process for the time being.
        callProcess1 wd cmd args = do
            -- note: the new process will inherit stdout/stdin/stderr from us,
            -- and will spam the console a bit. This will make the UI a bit
            -- ugly, but shouldn't cause any problems.
            (_, _, _, pHandle) <- createProcess (proc cmd args) {cwd = Just wd}
            ExitSuccess <- waitForProcess pHandle
            return ()
#endif

ghcArgsAsAgdaArgs :: GHCArgs -> AgdaArgs
ghcArgsAsAgdaArgs = map f
  where f = ("--ghc-flag=" ++)

agdaRunProgGoldenTest :: FilePath -- ^ path to the agda executable.
    -> FilePath     -- ^ directory where to run the tests.
    -> Compiler
    -> IO AgdaArgs     -- ^ extra Agda arguments
    -> FilePath -- ^ relative path to agda input file.
    -> TestOptions
    -> Maybe TestTree
agdaRunProgGoldenTest agdaBin dir comp extraArgs inp opts =
      agdaRunProgGoldenTest1 agdaBin dir comp extraArgs inp opts (\compDir -> do
        if executeProg opts then do
          -- read input file, if it exists
          inp' <- maybe T.empty decodeUtf8 <$> readFileMaybe inpFile
          -- now run the new program
          let exec = getExecForComp comp compDir inpFile
          res' <- PT.readProcessWithExitCode exec [] inp'
          return $ ExecutedProg res'
        else
          return $ CompileSucceeded
        )
  where inpFile = (dropExtension inp) <.> ".inp"

agdaRunProgGoldenTest1 :: FilePath -- ^ path to the agda executable.
    -> FilePath     -- ^ directory where to run the tests.
    -> Compiler
    -> IO AgdaArgs     -- ^ extra Agda arguments
    -> FilePath -- ^ relative path to agda input file.
    -> TestOptions
    -> (FilePath -> IO ExecResult) -- continuation if compile succeeds, gets the compilation dir
    -> Maybe TestTree
agdaRunProgGoldenTest1 agdaBin dir comp extraArgs inp opts cont
  | (Just cOpts) <- lookup comp (forCompilers opts) =
      Just $ goldenVsAction testName goldenFile (doRun cOpts) printExecResult
  | otherwise = Nothing
  where goldenFile = (dropExtension inp) <.> ".out"
        testName = dropExtension $ takeFileName inp

        doRun cOpts = withTempDirectory dir testName (\compDir -> do
          -- get extra arguments
          extraArgs' <- extraArgs
          -- compile file
          let defArgs = ["--ignore-interfaces", "--compile-dir", compDir] ++ extraArgs' ++ (extraAgdaArgs cOpts) ++ [inp]
          args <- (++ defArgs) <$> argsForComp comp
          res@(ret, _, _) <- PT.readProcessWithExitCode agdaBin args T.empty

          case ret of
            ExitSuccess -> cont compDir
            ExitFailure _ -> return $ CompileFailed res
          )

        argsForComp MAlonzo = return ["--compile"]
        argsForComp UHC     = do
            uhc <- getProg1 "UHC_BIN"
            let uhcBinArg = maybe [] (\x -> ["--uhc-bin", x]) uhc
            -- TODO remove the memory arg again, as soon as we fixed the memory leak
            return $ ["--uhc"] ++ uhcBinArg ++ ["+RTS", "-K50m", "-RTS"]

readOptions :: FilePath -- file name of the agda file
    -> IO TestOptions
readOptions inpFile =
  maybe defaultOptions (read . T.unpack . decodeUtf8) <$> readFileMaybe optFile
  where optFile = dropExtension inpFile <.> ".options"

-- gets the generated executable path
getExecForComp :: Compiler -> FilePath -> FilePath -> FilePath
getExecForComp MAlonzo compDir inpFile = compDir </> (takeFileName $ dropExtension inpFile)
getExecForComp UHC compDir inpFile = compDir </> "UHC" </> (takeFileName $ dropExtension inpFile)

printExecResult :: ExecResult -> T.Text
printExecResult (CompileFailed r) = "COMPILE_FAILED\n\n" `T.append` printProcResult r
printExecResult (CompileSucceeded) = "COMPILE_SUCCEEDED"
printExecResult (ExecutedProg r)  = "EXECUTED_PROGRAM\n\n" `T.append` printProcResult r
