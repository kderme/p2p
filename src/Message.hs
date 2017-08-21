{-# LANGUAGE RecordWildCards #-}
module Message where

import           Lib
import           Transactions
import           Peers

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

listen :: GlobalData -> IO ()
listen gdata@GlobalData{..} = do
    putStrLn $ "listening on " ++ show myPort
    s   <- listenOn (PortNumber myPort)
    forever $ do
        (h, hname, p) <- accept s
        forkFinally (waitConnection gdata (h, hname, p)) (const $ putStrLn "clientThread error")

waitConnection :: GlobalData -> (Handle, HostName, PortNumber) -> IO ()
waitConnection gdata@GlobalData{..} (h, cHostName, cPort) = do
  putStrLn $ "waiting for a Connect to Message from " ++ cHostName ++ ":" ++ show cPort
--  hSetNewlineMode h universalNewlineMode
--  hSetBuffering h LineBuffering
  msg <- hGetLine h
  print msg
  case read msg of
    Connect hostname port -> do
      peer <- newPeer gdata hostname port h
      peerThread gdata peer
    _ ->
      -- first message wasn`t Connect
      return ()


processMessage :: GlobalData -> PeerInfo -> Message -> IO ()
processMessage gdata@GlobalData{..} peer@PeerInfo{..} msg = do
  appendFile logMessages $ "[" ++ show piPort ++ "]  -> [" ++ show myPort ++ "]"  ++ show msg ++ "\n"
  case msg of
    Status peers -> undefined
    Connect hostname port -> do
        atomically $ del gpeers (Peer piHostName piPort)
--      atomically $ modifyTVar' (M.delete (Peer piHostName piPort)) gpeers
        return ()
    GetPeers -> do
        peers <- atomically $ readTVar gpeers -- ?
        send gdata (Status (M.keys peers)) piHandle
    Newtx tx -> do
        maybeTx <- atomically $ processNewTx tx gtxs
        timestamp <- getCurrentTime
        appendFile logfile ("Tx #: " ++ show tx ++ " from " ++ piHostName ++ " " ++ show timestamp ++ "\n")
        case maybeTx of
            Nothing            -> broadcast gdata (Newtx tx)
            Just newestTxKnown -> send gdata (Oldtx newestTxKnown tx) piHandle
    Quit -> do
        hClose piHandle
        tid <- myThreadId
        killThread tid
    Unknown str -> do
        putStrLn $ "Error unknown message given: " ++ show str
        return ()
    Oldtx newtx _ -> do
        atomically $ processNewTx newtx gtxs
        return ()
    Ping ->
        send gdata Pong piHandle
    Pong ->
        atomically $ writeTVar piRespond True

randomIntervals :: GlobalData -> IO ()
randomIntervals  gdata@GlobalData{..} = forever $ do
--    putStrLn $ "[" ++ show myPort ++ "] random Intervals"
    interval <- randomRIO(10,30)
    print interval
    threadDelay (interval*second)
    putStrLn $ "I just waited for " ++ show interval ++ "second"
    offset <- randomRIO(1,10)
    txs <- atomically $ readTVar gtxs
    peers <- atomically $ readTVar gpeers
    let recent = if null txs then 0 else head txs
    atomically $ processNewTx (recent+offset) gtxs
    -- TODO: log the new transaction
    timestamp <- getCurrentTime
    appendFile logfile ("Tx #: " ++ show (recent+offset) ++ " from me" ++ " " ++ show timestamp ++ "\n")
    --putStrLn "I am going to send now"
    broadcast gdata $ Newtx (recent+offset)
--    mapM_ (sendP gdata (Newtx (recent+offset))) $ M.toList peers


sendP1 :: GlobalData -> Message -> PeerInfo -> IO () -> IO ()
sendP1 gdata msg peer cont = sendP gdata msg peer >> cont

del :: TVar PeersDict -> Peer -> STM ()
del gpeers peer = do
  peers <- readTVar gpeers
  let newpeers = M.delete peer peers
  writeTVar gpeers newpeers

      --  atomically $

broadcast :: GlobalData -> Message -> IO ()
broadcast gdata@GlobalData{..} msg = do
        peers <- readTVarIO gpeers
        del <- readTVarIO delay
--        threadDelay(del*second)
        mapM_ (\ peer -> sendMessage gdata peer msg) (M.elems peers)

sendMessage :: GlobalData -> PeerInfo -> Message -> IO ()
sendMessage gdata@GlobalData{..} PeerInfo{..} msg = do
    appendFile logMessages $ "Chan : [" ++ show myPort ++ "] -> [" ++ show piPort ++ "]: " ++ show msg ++ "\n"
    atomically $ writeTChan piChan msg

send :: GlobalData -> Message -> Handle -> IO ()
send gdata@GlobalData{..} msg h = do
    appendFile logMessages $ "[" ++ show myPort ++ "] -> [????]: " ++ show msg ++ "\n"
    hPrint h msg

sendP :: GlobalData -> Message -> PeerInfo -> IO ()
sendP gdata@GlobalData{..} msg peer@PeerInfo{..} = do
    appendFile logMessages $ "[" ++ show myPort ++ "] -> [" ++ show piPort ++ "]: " ++ show msg ++ "\n"
    hPrint piHandle msg

peerThread :: GlobalData -> PeerInfo -> IO ()
peerThread gdata@GlobalData{..} peer@PeerInfo{..} = do
    putStrLn $ "peerThread for " ++ piHostName ++ ":" ++ show piPort
    hSetNewlineMode piHandle universalNewlineMode
    hSetBuffering piHandle LineBuffering
    race_ receive serve
--  putStrLn $ "Accepted connection from " ++ show cHostName ++ ":" ++ show cPort
    where
      receive :: IO ()
      receive = forever $ do
        appendFile logMessages "receive\n"
        msg <- hGetLine piHandle
        processMessage gdata peer (read msg)

      serve :: IO ()
      serve = do
        appendFile logMessages "serve\n"
        join $ atomically $ do
            msg <- readTChan piChan
            return $ sendP1 gdata msg peer serve

-- IO (Either SomeException PeerInfo)
connectToPeer :: GlobalData -> HostName -> PortNumber -> IO PeerInfo
connectToPeer gdata@GlobalData{..} hostname port = do
    putStrLn $ " connecting to peer " ++ hostname ++ ":" ++ show port
    h <- connectTo hostname $ PortNumber port
    peer <- newPeer gdata hostname port h
    forkFinally (peerThread gdata peer) (const $ putStrLn "clientThread error")
    -- TODO maybe make sure we listen before sending Connect message.
    send gdata (Connect myHostName myPort) h
    return peer -- $ Right peer

{-
sendIfPeer :: GlobalData -> HostName -> PortNumber -> Message  -> IO ()
sendIfPeer gdata@GlobalData{..} host port msg = do
  peers <- atomically $ readTVar gpeers
  let p = Peer host port
  case M.lookup p peers of
    Just pi  -> sendP gdata msg (p, piHandle pi)
    Nothing -> return ()
-}
