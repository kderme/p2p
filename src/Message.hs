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
    putStrLn $ "Entering Listening | on " ++ show myPort
    s   <- listenOn (PortNumber myPort)
    forever $ do
        (h, hname, p) <- accept s
        putStrLn "new Connection"
        forkFinally (waitConnection gdata (h, hname, p)) (const $ putStrLn "WAIT_CONNECTION FAILED")

waitConnection :: GlobalData -> (Handle, HostName, PortNumber) -> IO ()
waitConnection gdata@GlobalData{..} (h, cHostName, cPort) = do
    putStrLn $ "Entering waitConnection | from " ++ cHostName ++ ":" ++ show cPort
--  hSetNewlineMode h universalNewlineMode
--  hSetBuffering h LineBuffering
    msg <- hGetLine h
    case read msg of
        Connect hostname port -> do
            safeLogMsg lockMessages logMessages (read msg) port myPort
            peer <- newPeer gdata hostname port h
            tid <- forkFinally (peerThread gdata peer) (const $ putStrLn "PEER_THREAD RETURNED.")
            void $ forkFinally (readThread gdata peer) (const $ handleReadThread gdata peer tid)
        _ ->
            void $ putStrLn $ "WRONG FIRST MESSAGE | " ++ show msg
                ++ ",from" ++ cHostName ++ ":" ++ show cPort

processMessage :: GlobalData -> PeerInfo -> Message -> IO ()
processMessage gdata@GlobalData{..} peer@PeerInfo{..} msg = do
  safeLogMsg lockMessages logMessages msg piPort myPort
  case msg of
    Status peers -> return ()
    Connect hostname port -> do
        atomically $ del gpeers (Peer piHostName piPort)
--      atomically $ modifyTVar' (M.delete (Peer piHostName piPort)) gpeers
        return ()
    GetPeers -> do
        peers <- atomically $ readTVar gpeers -- ?
        writeToChan gdata peer (Status (M.keys peers))
        --send gdata (Status (M.keys peers)) piHandle
    Newtx tx -> do
        maybeTx <- atomically $ processNewTx tx gtxs
        timestamp <- getCurrentTime
        safeLog lockFile logFile $ "Tx #: " ++ show tx ++ " from " ++ piHostName
            ++ " " ++ show timestamp ++ "\n"
        case maybeTx of
          --
            Nothing            -> broadcast' gdata (Peer piHostName piPort) (Newtx tx)
            Just newestTxKnown -> writeToChan gdata peer (Oldtx newestTxKnown tx)
                --send gdata (Oldtx newestTxKnown tx) piHandle
    Quit ->
          deleteAndDie gdata peer
--        hClose piHandle
--        tid <- myThreadId
--        killThread tid
    Unknown str -> do
        putStrLn $ "Unknown message given: " ++ show str
        return ()
    Oldtx newtx _ -> do
        atomically $ processNewTx newtx gtxs
        return ()
    Ping ->
        undefined
        --send gdata Pong piHandle
    Pong ->
        atomically $ writeTVar piRespond True

del :: TVar PeersDict -> Peer -> STM ()
del gpeers peer = do
  peers <- readTVar gpeers
  let newpeers = M.delete peer peers
  writeTVar gpeers newpeers

deleteAndDie :: GlobalData -> PeerInfo -> IO ()
deleteAndDie gdata@GlobalData{..} peer@PeerInfo{..} = do
  putStrLn $ "Entering deleteAndDie | " ++ piHostName ++ ":" ++ show piPort
  putStrLn "GOODBYE CRUEL WORLD"
  atomically $ del gpeers $ Peer piHostName piPort
  hClose piHandle
  tid <- myThreadId
  killThread tid

randomIntervals :: GlobalData -> IO ()
randomIntervals  gdata@GlobalData{..} = do
  putStrLn "Entering Random_Intervals"
  forever $ do
    interval <- randomRIO(10,30)
    threadDelay (interval*second)
    offset <- randomRIO(1,10)
    txs <- atomically $ readTVar gtxs
    peers <- atomically $ readTVar gpeers
    let recent = if null txs then 0 else head txs
    atomically $ processNewTx (recent+offset) gtxs
    putStrLn $ "randomIntervals: After " ++ show interval ++ "s,  Tx = " ++ show (recent+offset)
    atomically (readTVar gtxs) >>= print
    -- TODO: log the new transaction
    timestamp <- getCurrentTime
    safeLog lockFile logFile $ "Tx #: " ++ show (recent+offset) ++ " from me"
        ++ " " ++ show timestamp ++ "\n"
    --putStrLn "I am going to send now"
    broadcast gdata $ Newtx (recent+offset)
--    mapM_ (sendP gdata (Newtx (recent+offset))) $ M.toList peers

broadcast :: GlobalData -> Message -> IO ()
broadcast gdata@GlobalData{..} msg = do
        putStrLn $ "Entering broadcast " ++ show msg
        peers <- readTVarIO gpeers
        del <- readTVarIO delay
        -- >> threadDelay(del*second)
        mapM_ (\ peer -> writeToChan gdata peer msg) (M.elems peers)

broadcast' :: GlobalData -> Peer -> Message -> IO ()
broadcast' gdata@GlobalData{..} pswriarhs msg = do
        putStrLn $ "Entering broadcast' " ++ show msg
        peers <- readTVarIO gpeers
        del <- readTVarIO delay
--        threadDelay(del*second)
        mapM_ (\ peer -> writeToChan gdata (peers M.! peer) msg)
            (filter (/= pswriarhs) $ M.keys peers)

peerThread :: GlobalData -> PeerInfo -> IO ()
peerThread gdata@GlobalData{..} peer@PeerInfo{..} = do
    putStrLn $ "Entering peerThread | on " ++ piHostName ++ ":" ++ show piPort
--    hSetNewlineMode piHandle universalNewlineMode
--    hSetBuffering piHandle LineBuffering
    void $ forever $ do
        msg <- atomically $ readTChan piChan
        sendP gdata msg peer

connectToPeer :: GlobalData -> HostName -> PortNumber -> IO PeerInfo
connectToPeer gdata@GlobalData{..} hostname port = do
    putStrLn $ "Entering connectToPeer " ++ hostname ++ ":" ++ show port
    h <- connectTo hostname $ PortNumber port
    peer <- newPeer gdata hostname port h
    tid <- forkFinally (peerThread gdata peer) (const $ putStrLn "PEER_THREAD RETURNED.")
    forkFinally (readThread gdata peer) (const $ handleReadThread gdata peer tid)
    -- TODO maybe make sure we listen before sending Connect message.
    sendP gdata (Connect myHostName myPort) peer
    return peer -- $ Right peer

handleReadThread :: GlobalData -> PeerInfo -> ThreadId -> IO ()
handleReadThread gdata@GlobalData{..} peer@PeerInfo{..} tid = do
  putStrLn "READ_THREAD RETURNED."
  killThread tid
  deleteAndDie gdata peer

readThread :: GlobalData -> PeerInfo -> IO ()
readThread gdata@GlobalData{..} peer@PeerInfo{..} = do
    putStrLn $ "Entering readThread | on " ++ piHostName ++ ":" ++ show piPort
    hSetNewlineMode piHandle universalNewlineMode
    hSetBuffering piHandle LineBuffering
    forever $ do
    --  putStrLn $ "readThread loop " ++ show piPort ++ "\n"
        msg <- hGetLine piHandle
        processMessage gdata peer (read msg)

writeToChan :: GlobalData -> PeerInfo -> Message -> IO ()
writeToChan gdata@GlobalData{..} PeerInfo{..} msg =
--    putStrLn $ "Chan : [" ++ show myPort ++ "] -> [" ++ show piPort ++ "]: " ++ show msg ++ "\n"
    atomically $ writeTChan piChan msg

send :: GlobalData -> Message -> Handle -> IO ()
send gdata@GlobalData{..} msg h = do
    putStrLn $ "[" ++ show myPort ++ "] -> [????]: " ++ show msg ++ "\n"
    hPrint h msg

sendP :: GlobalData -> Message -> PeerInfo -> IO ()
sendP gdata@GlobalData{..} msg peer@PeerInfo{..} = do
    putStrLn $ "[" ++ show myPort ++ "] -> [" ++ show piPort ++ "]: " ++ show msg
    hPrint piHandle msg


{-
sendIfPeer :: GlobalData -> HostName -> PortNumber -> Message  -> IO ()
sendIfPeer gdata@GlobalData{..} host port msg = do
  peers <- atomically $ readTVar gpeers
  let p = Peer host port
  case M.lookup p peers of
    Just pi  -> sendP gdata msg (p, piHandle pi)
    Nothing -> return ()
-}
