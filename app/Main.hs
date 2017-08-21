{-# LANGUAGE RecordWildCards #-}
module Main where

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

import           Lib

-- Peer interface --

data Peer =
    Peer
        { hostName :: HostName
        , port     :: PortNumber
        } deriving (Show, Read,Eq,Ord)

data PeerInfo =
    PeerInfo
      { piHostName :: HostName
      , piPort     :: PortNumber
      , piHandle   :: Handle
      , piChan     :: TChan Message
      , piRespond  :: TVar Bool
    }

type Peers = [Peer]
type PeersDict = M.Map Peer PeerInfo -- [(Peer, Handle)]

newPeers :: IO (TVar PeersDict)
newPeers = newTVarIO M.empty

-- End of Peer interface --

data GlobalData =
    GlobalData
        { myHostName   :: HostName
        , myPort       :: PortNumber
        , logfile      :: FilePath
        , logMessages  :: FilePath
        , delay        :: TVar Int
        , gpeers       :: TVar PeersDict
        , gtxs         :: TVar Transactions
        }

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
  appendFile logm $ "Logging for " ++ show host ++ ":" ++ show port ++ "\n"
  del <- newTVarIO delay
  return $ GlobalData host port log logm del gpeers gtxs

{-
newDefaultGlobalData :: IO GlobalData
newDefaultGlobalData = newGlobalData "127.0.0.1" 4000 5
-}

data Message =
    Connect HostName PortNumber
    | GetPeers
    | Status Peers
    | Newtx Tx
    | Oldtx Tx Tx
    | Quit
    | Unknown String
    | Ping
    | Pong
    deriving (Read, Show)

-- Transactions Interface --

type Tx = Int
type Transactions = [Tx]
type Port = Int
newTransactions :: IO (TVar Transactions)
newTransactions = newTVarIO []

isNew :: Transactions -> Tx -> Bool
isNew [] tx     = True
isNew (x:xs) tx = tx > x

getNew :: Transactions -> Tx
getNew = head

--
-- STM Nothing   means that a new Transaction was found. Insert it!
-- STM (Just tx) means that this transactions exists/is old. Return the newest!
--

processNewTx :: Tx -> TVar Transactions -> STM (Maybe Tx)
processNewTx newtx txs' = do
    txs <- readTVar txs'
    if isNew txs newtx
    then do
        writeTVar txs' (newtx:txs)
        return Nothing
    else
        return $ Just $ getNew txs

-- End of Transaction Interface --
second :: Int
second = 1000000

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
    deriving (Show, Read)

trying :: String -> String
trying "_" = "127.0.0.1"
trying str = str

main :: IO ()
main = do
    gpeers <- newPeers --global Peers TVar
    gtxs <- newTransactions --global Transactions TVar
    args <- getArgs
    let myPort = read $ head args
    let seedHostName = trying $ args !! 1
    let seedPort = read $ args !! 2
    let delay = read $ args !! 3
    let myHostName = if length args <5 then "127.0.0.1" else args !! 4
    gpeers <- newPeers --global Peers TVar
    gtxs <- newTransactions --global Transactions TVar
    gdata <- newGlobalData myHostName myPort delay gpeers gtxs
    interactive gdata seedHostName seedPort

interactive:: GlobalData -> HostName -> PortNumber -> IO ()
interactive gdata@GlobalData{..} seedHostName seedPortName =
    forever $ do
        line <- getLine
        let command = read line
        case command of
            Run                    -> void $ forkIO $ run gdata seedHostName seedPortName
            LearnPeers host port n -> void $ forkIO $ learnPeers gdata host port n
            ShowPeers              -> M.keys <$> atomically (readTVar gpeers) >>= print
            ShowTxs                -> atomically (readTVar gtxs) >>= print
--            Send host port msg     -> void $ forkIO $ sendIfPeer gdata host port msg
            SetDelay val           -> atomically $ writeTVar delay val
            PingPong               -> void $ forkIO $ triggerPing gdata
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

{-
deletePeer :: GlobalData -> Peer -> STM ()
deletePeer gdata@GlobalData{..} peer =
-}

learnPeers :: GlobalData -> HostName -> PortNumber -> Int -> IO ()
learnPeers gdata@GlobalData{..} seedHostName seedPort target = do
    l <- go (3*target+1) [] seedHostName seedPort -- for num==3, 3n+1==10 .
    let l3 = take (min target (length l)) l
    mapM_ (\(Peer host port) -> forkIO (void $ connectToPeer gdata seedHostName seedPort)) l3
      where
        go n possible_conn hostname cport
            | n < 0     = return possible_conn
            | otherwise = do
                PeerInfo{..} <- connectToPeer gdata hostname cport -- :: IO (Either SomeException PeerInfo)
{-              case con of

                    Left _ -> do
                        putStrLn ("Could not connect to " ++ hostname ++ ":" ++ show cport)
                        return []
-}
--                    Right PeerInfo{..} -> do
                send gdata GetPeers piHandle
                answer <- hGetLine piHandle
                let Status p = read answer
                if null p
                then return [Peer hostname cport]
                else do
                    let (Peer nexthost nextport) = head p
                    hClose piHandle
                    go (n-length p) (possible_conn ++ p) nexthost nextport

newPeer :: GlobalData -> HostName -> PortNumber -> Handle -> IO PeerInfo
newPeer GlobalData{..} hostname port h = do
    chan   <- newTChanIO
    responding <- newTVarIO True
    let peer = PeerInfo hostname port h chan responding
    atomically $ modifyTVar' gpeers $ M.insert (Peer hostname port) peer
    return peer

connectToPeer :: GlobalData -> HostName -> PortNumber -> IO PeerInfo -- IO (Either SomeException PeerInfo)
connectToPeer gdata@GlobalData{..} hostname port = do
    putStrLn $ " connecting to peer " ++ hostname ++ ":" ++ show port
    h <- connectTo hostname $ PortNumber port
    peer <- newPeer gdata hostname port h
    forkFinally (peerThread gdata peer) (const $ putStrLn "clientThread error")
    -- TODO maybe make sure we listen before sending Connect message.
    send gdata (Connect myHostName myPort) h
    return peer -- $ Right peer

listen :: GlobalData -> IO ()
listen gdata@GlobalData{..} = do
    putStrLn $ "listening on " ++ show myPort
    s   <- listenOn (PortNumber myPort)
    forever $ do
        (h, hname, p) <- accept s
        forkFinally (waitConnection gdata (h, hname, p)) (const $ putStrLn "clientThread error")

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

sendP1 :: GlobalData -> Message -> PeerInfo -> IO () -> IO ()
sendP1 gdata msg peer cont = sendP gdata msg peer >> cont

del :: TVar PeersDict -> Peer -> STM ()
del gpeers peer = do
  peers <- readTVar gpeers
  let newpeers = M.delete peer peers
  writeTVar gpeers newpeers

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

{-
sendIfPeer :: GlobalData -> HostName -> PortNumber -> Message  -> IO ()
sendIfPeer gdata@GlobalData{..} host port msg = do
  peers <- atomically $ readTVar gpeers
  let p = Peer host port
  case M.lookup p peers of
    Just pi  -> sendP gdata msg (p, piHandle pi)
    Nothing -> return ()
-}

--TODO use chans for each peer (add to record) . Else just open a new connection
