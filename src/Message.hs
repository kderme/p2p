{-# LANGUAGE RecordWildCards #-}
module Message where

import           Lib
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
            forkIO $ readThread gdata peer
            peerThread gdata peer
        _ ->
            void $ putStrLn $ "My peer" ++ cHostName ++ ":" ++ show cPort
            ++ "didnt send Connect as his first message"


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
        sendMessage gdata peer (Status (M.keys peers))
        --send gdata (Status (M.keys peers)) piHandle
    Newtx tx -> do
        maybeTx <- atomically $ processNewTx tx gtxs
        timestamp <- getCurrentTime
        appendFile logfile ("Tx #: " ++ show tx ++ " from " ++ piHostName ++ " " ++ show timestamp ++ "\n")
        case maybeTx of
            Nothing            -> broadcast gdata (Newtx tx)
            Just newestTxKnown -> sendMessage gdata peer (Oldtx newestTxKnown tx)
                --send gdata (Oldtx newestTxKnown tx) piHandle
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
        undefined
        --send gdata Pong piHandle
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


--sendP1 :: GlobalData -> Message -> PeerInfo -> IO () -> IO ()
--sendP1 gdata msg peer cont = sendP gdata msg peer >> cont

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
    void $ forever serve
    where
    serve :: IO ()
    serve = do
        appendFile logMessages "serve\n"
        join $ atomically $ do
            msg <- readTChan piChan
            return $ sendP gdata msg peer

-- IO (Either SomeException PeerInfo)
connectToPeer :: GlobalData -> HostName -> PortNumber -> IO PeerInfo
connectToPeer gdata@GlobalData{..} hostname port = do
    putStrLn $ " connecting to peer " ++ hostname ++ ":" ++ show port
    h <- connectTo hostname $ PortNumber port
    peer <- newPeer gdata hostname port h
    forkIO $ readThread gdata peer
    forkFinally (peerThread gdata peer) (const $ putStrLn "clientThread error")
    -- TODO maybe make sure we listen before sending Connect message.
    sendP gdata (Connect myHostName myPort) peer
    return peer -- $ Right peer


readThread :: GlobalData -> PeerInfo -> IO ()
readThread gdata@GlobalData{..} peer@PeerInfo{..} = do
    putStrLn $ "readThread for " ++ piHostName ++ ":" ++ show piPort
    hSetNewlineMode piHandle universalNewlineMode
    hSetBuffering piHandle LineBuffering
    forever $ do
        msg <- hGetLine piHandle
        processMessage gdata peer (read msg)

{-
sendIfPeer :: GlobalData -> HostName -> PortNumber -> Message  -> IO ()
sendIfPeer gdata@GlobalData{..} host port msg = do
  peers <- atomically $ readTVar gpeers
  let p = Peer host port
  case M.lookup p peers of
    Just pi  -> sendP gdata msg (p, piHandle pi)
    Nothing -> return ()
-}
