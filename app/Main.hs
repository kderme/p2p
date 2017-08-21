module Main where

import           Discovery
import           Interactive
import           Lib
import           Message
import           Peers
import           Transactions

import           Control.Concurrent
import           Control.Concurrent.Async
import           Control.Concurrent.STM
import           Control.Exception
import           Control.Monad
import           Data.IORef
import           Data.List
import qualified Data.Map                 as M
import           Data.Time
import           Network
import           System.Directory
import           System.Environment
import           System.IO
import           System.Random

newGlobalData :: HostName -> PortNumber -> Int -> TVar PeersDict -> TVar Transactions-> IO GlobalData
newGlobalData host port delay gpeers gtxs = do
  let logpath = "logging/" ++ show port
  bl <- doesPathExist logpath
  if bl
  then do
      removeDirectoryRecursive logpath
      createDirectory logpath
  else
      createDirectory logpath
  let
    log = logpath ++ "/txs"
    logm = logpath ++ "/messages"
  lock <- newMVar ()
  lockm <- newMVar ()
  appendFile logm $ "Logging for " ++ show host ++ ":" ++ show port ++ "\n"
  del <- newTVarIO delay
  return $ GlobalData host port lock log lockm logm del gpeers gtxs

main :: IO ()
main = do
    gpeers <- newPeers --global Peers TVar
    gtxs <- newTransactions --global Transactions TVar
    args <- getArgs
    when (length args < 4) (return ())
    let myPort = read $ head args
        seedHostName = trying $ args !! 1
        seedPort = read $ args !! 2
        delay = read $ args !! 3
        myHostName = if length args <5 then "127.0.0.1" else args !! 4
    gpeers <- newPeers --global Peers TVar
    gtxs <- newTransactions --global Transactions TVar
    gdata <- newGlobalData myHostName myPort delay gpeers gtxs
    interactive gdata seedHostName seedPort
