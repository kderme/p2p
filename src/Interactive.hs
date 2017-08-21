{-# LANGUAGE RecordWildCards #-}
module Interactive where

import           Discovery
import           Lib
import           Message
import           Peers
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

data InterMsg =
    Run
    | Listen
    | LearnPeers HostName PortNumber Int
    | ShowTxs
    | ShowPeers
    | SetArgs
    | Send HostName PortNumber Message
    | SetDelay Int
    | PingPong
    | LowBound HostName PortNumber Int
    | Graph HostName PortNumber
    deriving (Show, Read)

interactive :: GlobalData -> HostName -> PortNumber -> IO ()
interactive gdata@GlobalData{..} seedHostName seedPortName =
    forever $ do
        line <- getLine
        let command = read line
        case command of
            Run                    -> void $ forkIO $ run gdata seedHostName seedPortName
            LearnPeers host port n -> void $ forkIO $ learnPeers gdata host port n
            ShowPeers              -> M.keys <$> atomically (readTVar gpeers) >>= print
            ShowTxs                -> atomically (readTVar gtxs) >>= print
--          Send host port msg     -> void $ forkIO $ sendIfPeer gdata host port msg
            SetDelay val           -> atomically $ writeTVar delay val
            PingPong               -> void $ forkIO $ triggerPing gdata
            LowBound host port n   -> void $ forkIO $ triggerLearn gdata host port n
--            Graph host port        -> void $ forkIO createGraph gdata host port
            _                      -> putStrLn "Command not defined yet"

run ::  GlobalData -> HostName -> PortNumber -> IO ()
run gdata@GlobalData{..} seedHostName seedPort = do
    forkFinally (listen gdata) (const $ putStrLn $ "I cannot listen on port: "++ show myPort)
    forkIO $ learnPeers gdata seedHostName seedPort 3 -- 3 is the default
    forkFinally (randomIntervals gdata) (const $ putStrLn "Random intervals ended unexpectedly")
    return ()

triggerPing :: GlobalData -> IO ()
triggerPing gdata@GlobalData{..} = forever $ do
  threadDelay (120*second)
  atomically $ do
    peers <- readTVar gpeers
    mapM_ (\ peer@PeerInfo{..} -> writeTVar piRespond False) $ M.elems peers
  broadcast gdata Ping
  threadDelay (60*second)
  atomically $ do
    peers <- readTVar gpeers
    fpeers <- filterM ( readTVar . piRespond . snd) $ M.toList peers
    let newPeers = foldl (flip M.delete) peers $ map fst fpeers
    writeTVar gpeers newPeers

triggerLearn :: GlobalData -> HostName -> PortNumber -> Int -> IO ()
triggerLearn gdata@GlobalData{..} seedHostName seedPort target = loop
    where
  loop :: IO ()
  loop = do
    threadDelay (150*second)
    putStrLn "Trigger learn"
    n <- atomically $ do
      peers <- readTVar gpeers
      return $ M.size peers
    if n < target then do
      putStrLn $ "Left with " ++ show n ++ " Peers."
      void $ forkIO $ learnPeers gdata seedHostName seedPort target
      return ()
    else
      loop

createGraph :: GlobalData -> HostName -> PortNumber -> IO ()
createGraph gdata host port =
  learnPeers gdata host port 10
