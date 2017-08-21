{-# LANGUAGE RecordWildCards #-}
module Peers where

import           Lib
import           Transactions

import           Control.Concurrent
import           Control.Concurrent.STM
import           Control.Exception
import           Control.Monad
import           Control.Concurrent.Async
import           Data.List
import           Data.Time
import qualified Data.Map as M
import           Data.IORef
import           Network
import           System.Environment
import           System.IO
import           System.Random
import           System.Directory

newPeers :: IO (TVar PeersDict)
newPeers = newTVarIO M.empty

newPeer :: GlobalData -> HostName -> PortNumber -> Handle -> IO PeerInfo
newPeer GlobalData{..} hostname port h = do
    putStrLn $ "Entering newPeer | " ++ hostname ++ ":" ++ show port
    chan   <- newTChanIO
    responding <- newTVarIO True
    let peer = PeerInfo hostname port h chan responding
    atomically $ modifyTVar' gpeers $ M.insert (Peer hostname port) peer
    return peer
