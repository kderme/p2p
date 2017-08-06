{-# LANGUAGE CPP #-}
{-# OPTIONS_GHC -fno-warn-missing-import-lists #-}
{-# OPTIONS_GHC -fno-warn-implicit-prelude #-}
module Paths_p2p (
    version,
    getBinDir, getLibDir, getDynLibDir, getDataDir, getLibexecDir,
    getDataFileName, getSysconfDir
  ) where

import qualified Control.Exception as Exception
import Data.Version (Version(..))
import System.Environment (getEnv)
import Prelude

#if defined(VERSION_base)

#if MIN_VERSION_base(4,0,0)
catchIO :: IO a -> (Exception.IOException -> IO a) -> IO a
#else
catchIO :: IO a -> (Exception.Exception -> IO a) -> IO a
#endif

#else
catchIO :: IO a -> (Exception.IOException -> IO a) -> IO a
#endif
catchIO = Exception.catch

version :: Version
version = Version [0,1,0,0] []
bindir, libdir, dynlibdir, datadir, libexecdir, sysconfdir :: FilePath

bindir     = "C:\\Users\\alexm\\Desktop\\team-unsafePerformIO\\.stack-work\\install\\6c953ab2\\bin"
libdir     = "C:\\Users\\alexm\\Desktop\\team-unsafePerformIO\\.stack-work\\install\\6c953ab2\\lib\\x86_64-windows-ghc-8.0.2\\p2p-0.1.0.0-6n0WPTa0UB8GnQlfIhCsVe"
dynlibdir  = "C:\\Users\\alexm\\Desktop\\team-unsafePerformIO\\.stack-work\\install\\6c953ab2\\lib\\x86_64-windows-ghc-8.0.2"
datadir    = "C:\\Users\\alexm\\Desktop\\team-unsafePerformIO\\.stack-work\\install\\6c953ab2\\share\\x86_64-windows-ghc-8.0.2\\p2p-0.1.0.0"
libexecdir = "C:\\Users\\alexm\\Desktop\\team-unsafePerformIO\\.stack-work\\install\\6c953ab2\\libexec"
sysconfdir = "C:\\Users\\alexm\\Desktop\\team-unsafePerformIO\\.stack-work\\install\\6c953ab2\\etc"

getBinDir, getLibDir, getDynLibDir, getDataDir, getLibexecDir, getSysconfDir :: IO FilePath
getBinDir = catchIO (getEnv "p2p_bindir") (\_ -> return bindir)
getLibDir = catchIO (getEnv "p2p_libdir") (\_ -> return libdir)
getDynLibDir = catchIO (getEnv "p2p_dynlibdir") (\_ -> return dynlibdir)
getDataDir = catchIO (getEnv "p2p_datadir") (\_ -> return datadir)
getLibexecDir = catchIO (getEnv "p2p_libexecdir") (\_ -> return libexecdir)
getSysconfDir = catchIO (getEnv "p2p_sysconfdir") (\_ -> return sysconfdir)

getDataFileName :: FilePath -> IO FilePath
getDataFileName name = do
  dir <- getDataDir
  return (dir ++ "\\" ++ name)
