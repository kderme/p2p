{-# LANGUAGE RecordWildCards #-}
module Message where

import           Lib
import           Peers
import           Transactions

import           Control.Concurrent
import           Control.Concurrent.STM
import           Control.Monad
import qualified Data.Map                 as M
import           Data.Time
import           Network
import           System.IO
import           System.Random

listen :: GlobalData -> IO ()
listen gdata@GlobalData{..} = do
    putStrLn $ "Entering Listening | on " ++ show myPort
    s   <- listenOn (PortNumber myPort)
    forever $ do
        (h, hname, p) <- accept s
--        hSetNewlineMode h universalNewlineMode
--        hSetBuffering h LineBuffering
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
    Status _ -> return ()
    Connect _ _ -> do
        atomically $ del gpeers (Peer piHostName piPort)
        return ()
    GetPeers -> do
        peers <- atomically $ readTVar gpeers -- ?
        writeToChan gdata peer (Status (M.keys peers))
        --send gdata (Status (M.keys peers)) piHandle
    Newtx tx -> do
        maybeTx <- atomically $ processNewTx tx gtxs
        timestamp <- getCurrentTime
        safeLog lockFile logFile $ "Tx #: " ++ show tx ++ " from " ++ piHostName ++ ":"
            ++ show piPort ++ " " ++ show timestamp ++ "\n"
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
    Ping -> do
        p <- readTVarIO pong
        when p $ send gdata Pong piHandle
    Pong ->
        atomically $ writeTVar piRespond True

-- | A helper function that deletes the given peer from the given Map.
del :: TVar PeersDict -> Peer -> STM ()
del gpeers peer = do
  peers <- readTVar gpeers
  let newpeers = M.delete peer peers
  writeTVar gpeers newpeers

-- | A function that deletes the given peer from the peer
-- list, closes its handle and kills the thread on which
-- is running.
deleteAndDie :: GlobalData -> PeerInfo -> IO ()
deleteAndDie GlobalData{..} PeerInfo{..} = do
  putStrLn $ "Entering deleteAndDie | " ++ piHostName ++ ":" ++ show piPort
  putStrLn "GOODBYE CRUEL WORLD"
  atomically $ del gpeers $ Peer piHostName piPort
  hClose piHandle
  tid <- myThreadId
  killThread tid

-- | With this function at random intervals (between 10
-- seconds and one minute) generates a new transaction,
-- which is between 1 and 10 higher than the most recent
-- known transaction, logs it and sends it to its peers.
randomIntervals :: GlobalData -> IO ()
randomIntervals  gdata@GlobalData{..} = do
  putStrLn "Entering Random_Intervals"
  forever $ do
    interval <- randomRIO(10,60)
    threadDelay (interval*second)
    offset <- randomRIO(1,10)
    txs <- atomically $ readTVar gtxs
    let recent = if null txs then 0 else head txs
    atomically $ processNewTx (recent+offset) gtxs
    putStrLn $ "randomIntervals: After " ++ show interval ++ "s,  Tx = " ++ show (recent+offset)
    atomically (readTVar gtxs) >>= print
    timestamp <- getCurrentTime
    safeLog lockFile logFile $ "Tx #: " ++ show (recent+offset) ++ " from me"
        ++ " " ++ show timestamp ++ "\n"
    broadcast gdata $ Newtx (recent+offset)

-- | With this function a peer sends a message to its peers.
broadcast :: GlobalData -> Message -> IO ()
broadcast gdata@GlobalData{..} msg = do
        putStrLn $ "Entering broadcast " ++ show msg
        peers <- readTVarIO gpeers
        -- del <- readTVarIO delay
        -- threadDelay(del*second)
        mapM_ (\ peer -> writeToChan gdata peer msg) (M.elems peers)

-- | With this function a peer sends a message to its peers
-- except from the given one.
broadcast' :: GlobalData -> Peer -> Message -> IO ()
broadcast' gdata@GlobalData{..} parasite msg = do
        putStrLn $ "Entering broadcast' " ++ show msg
        peers <- readTVarIO gpeers
        delay' <- readTVarIO delay
        -- threadDelay(delay'*second)
        let
            delayAndWrite peer = do
                threadDelay(delay'*second)
                writeToChan gdata (peers M.! peer) msg
        mapM_ delayAndWrite (filter (/= parasite) $ M.keys peers)


-- | A function that reads from the channel of a peer and
-- sends it to its handle. Using a channel we are sure
-- that outcoming messages will not be written in the
-- handle at the same time.
peerThread :: GlobalData -> PeerInfo -> IO ()
peerThread gdata@GlobalData{..} peer@PeerInfo{..} = do
    putStrLn $ "Entering peerThread | on " ++ piHostName ++ ":" ++ show piPort
    -- hSetNewlineMode piHandle universalNewlineMode
    -- hSetBuffering piHandle LineBuffering
    void $ forever $ do
        msg <- atomically $ readTChan piChan
        sendP gdata msg peer

-- | A function that connects to a peer and adds it to its
-- peer list.
connectToPeer :: GlobalData -> HostName -> PortNumber -> IO PeerInfo
connectToPeer gdata@GlobalData{..} hostname port = do
    putStrLn $ "Entering connectToPeer " ++ hostname ++ ":" ++ show port
    h <- connectTo hostname $ PortNumber port
    peer <- newPeer gdata hostname port h
    tid <- forkFinally (peerThread gdata peer) (const $ putStrLn "PEER_THREAD RETURNED.")
    forkFinally (readThread gdata peer) (const $ handleReadThread gdata peer tid)
    -- TODO maybe make sure we listen before sending Connect message.
    sendP gdata (Connect myHostName myPort) peer
    return peer

-- | If readThread dies then peer will delete the
-- disconnected peer from its peer list and kill
-- the thread that .
handleReadThread :: GlobalData -> PeerInfo -> ThreadId -> IO ()
handleReadThread gdata@GlobalData{..} peer@PeerInfo{..} tid = do
  putStrLn "READ_THREAD RETURNED."
  killThread tid
  deleteAndDie gdata peer

-- | A function that reads messages from the given peer
-- handle and processes them.
readThread :: GlobalData -> PeerInfo -> IO ()
readThread gdata@GlobalData{..} peer@PeerInfo{..} = do
    putStrLn $ "Entering readThread | on " ++ piHostName ++ ":" ++ show piPort
--    hSetNewlineMode piHandle universalNewlineMode
--    hSetBuffering piHandle LineBuffering
    forever $ do
    --  putStrLn $ "readThread loop " ++ show piPort ++ "\n"
        msg <- hGetLine piHandle
        processMessage gdata peer (read msg)

-- | Writes the given message to the channel of given peer.
writeToChan :: GlobalData -> PeerInfo -> Message -> IO ()
writeToChan GlobalData{..} PeerInfo{..} msg =
--    putStrLn $ "Chan : [" ++ show myPort ++ "] -> [" ++ show piPort ++ "]: " ++ show msg ++ "\n"
    atomically $ writeTChan piChan msg

-- | Sends a message through the given handle.
send :: GlobalData -> Message -> Handle -> IO ()
send GlobalData{..} msg h = do
    safeLogMsg lockMessages logMessages msg myPort 0
    putStrLn $ "[" ++ show myPort ++ "] -> [????]: " ++ show msg ++ "\n"
    hPrint h msg

-- | Sends a message to the given peer through its handle.
sendP :: GlobalData -> Message -> PeerInfo -> IO ()
sendP GlobalData{..} msg PeerInfo{..} = do
    putStrLn $ "[" ++ show myPort ++ "] -> [" ++ show piPort ++ "]: " ++ show msg
    hPrint piHandle msg
