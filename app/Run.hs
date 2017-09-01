module Main where

import           Interactive
import           Lib
import           Peers
import           Transactions

import           Control.Concurrent
import           Control.Concurrent.STM
import           Control.Monad
import           Network
import           Prelude hiding (log)
import           System.Directory
import           System.Environment

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
  pong <- newTVarIO True
  return $ GlobalData host port lock log lockm logm del gpeers gtxs pong

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
    run gdata seedHostName seedPort
    interactive gdata seedHostName seedPort
