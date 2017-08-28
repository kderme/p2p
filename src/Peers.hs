{-# LANGUAGE RecordWildCards #-}
module Peers where

import           Lib

import           Control.Concurrent.STM
import qualified Data.Map as M
import           Network
import           System.IO

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