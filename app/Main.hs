{-# LANGUAGE RecordWildCards #-}
module Main where

import           Control.Concurrent
import           Control.Concurrent.STM
import           Control.Exception
import           Control.Monad
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

type Peers = [Peer]
type PeersHandle = M.Map Peer Handle -- [(Peer, Handle)]

newPeers :: IO (TVar PeersHandle)
newPeers = newTVarIO M.empty

-- End of Peer interface --

data GlobalData =
    GlobalData
        { myHostName   :: HostName
        , myPort       :: PortNumber
        , logfile      :: FilePath
        , logMessages  :: FilePath
        , delay        :: TVar Int
        }

newGlobalData :: HostName -> PortNumber -> Int -> IO GlobalData
newGlobalData host port delay = do
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
  del <- newTVarIO delay
  return $ GlobalData host port log logm del

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
    deriving (Read, Show)

data GlobalTVars =
    GlobalTVars
        { gpeers :: TVar PeersHandle
        , gtxs   :: TVar Transactions
        }

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
    deriving (Show, Read)

main :: IO ()
main = do
    gpeers <- newPeers --global Peers TVar
    gtxs <- newTransactions --global Transactions TVar
    args <- getArgs
    let myPort = read $ head args
    let seedHostName = args !! 1
    let seedPort = read $ args !! 2
    let delay = read $ args !! 3
    let myHostName = if length args <5 then "127.0.0.1" else args !! 4
    gpeers <- newPeers --global Peers TVar
    gtxs <- newTransactions --global Transactions TVar
    gdata <- newGlobalData myHostName myPort delay
    let gtv = GlobalTVars gpeers gtxs
    interactive gdata seedHostName seedPort gtv

interactive:: GlobalData -> HostName -> PortNumber -> GlobalTVars -> IO ()
interactive gdata@GlobalData{..} seedHostName seedPortName gtv@GlobalTVars{..} =
    forever $ do
        line <- getLine
        let command = read line
        case command of
            Run                    -> void $ forkIO $ run gdata seedHostName seedPortName gtv
--          Listen                 -> void $ forkIO $ listen myPort "log_txos" delay gtv
            LearnPeers host port n -> void $ forkIO $ learnPeers gdata host port n gtv
            ShowPeers              -> atomically (readTVar gpeers) >>= print
            ShowTxs                -> atomically (readTVar gtxs) >>= print
            Send host port msg     -> void $ forkIO $ sendIfPeer gdata host port msg gtv
            SetDelay val           -> atomically $ writeTVar delay val
            _                      -> putStrLn "Command not defined yet"
--    return ()

sendIfPeer :: GlobalData -> HostName -> PortNumber -> Message -> GlobalTVars -> IO ()
sendIfPeer gdata@GlobalData{..} host port msg gtv@GlobalTVars{..} = do
  peers <- atomically $ readTVar gpeers
  let p = Peer host port
  case M.lookup p peers of
    Just h  -> sendP gdata msg (p, h)
    Nothing -> return ()

learnPeers :: GlobalData -> HostName -> PortNumber -> Int -> GlobalTVars -> IO ()
learnPeers gdata@GlobalData{..} seedHostName seedPort num gtv@GlobalTVars{..} = do
    l <- go (3*num+1) [] seedHostName seedPort -- for num==3, 3n+1==10 .
    let l3 = take (min num (length l)) l
    mapM_ (\(Peer host port) -> forkIO (connectToPeer gdata seedPort seedHostName gtv)) l3 --TODO styling
    return ()
    where
        go n possible_conn hostname cport
            | n < 0     = return possible_conn
            | otherwise = do
                con <- try (connectTo hostname $ PortNumber cport) :: IO (Either SomeException Handle)
                case con of
                    Left _ -> do
                        putStrLn ("Could not connect to " ++ hostname ++ ":" ++ show cport)
                        return []
                    Right h -> do
                        send gdata GetPeers h
                        answer <- hGetLine h
                        let Status p = read answer
                        if null p
                        then return [Peer hostname cport]
                        else do
                            let (Peer nexthost nextport) = head p
                            hClose h
                            go (n-length p) (possible_conn ++ p) nexthost nextport

connectToPeer :: GlobalData -> PortNumber -> HostName -> GlobalTVars -> IO ()
connectToPeer gdata@GlobalData{..} port hostname gtv@GlobalTVars{..} = do
    putStrLn $ "[" ++ show myPort ++ "] connecting to peer"
    h <- connectTo hostname $ PortNumber port
    atomically $ modifyTVar' gpeers $ M.insert (Peer hostname port) h
    send gdata (Connect myHostName myPort) h

listen :: GlobalData -> GlobalTVars -> IO ()
listen gdata@GlobalData{..} gtv@GlobalTVars{..} = do
    putStrLn $ "[" ++ show myPort ++ "] listening"
    putStrLn "listening"
    s   <- listenOn (PortNumber myPort)
    forever $ do
        (h, hname, p) <- accept s
        forkFinally (clientThread gdata (h, hname, p) gtv) (const $ putStrLn "clientThread error")
        --find PeerToDelete from PeersHandle and then
        --atomically $ modifyTVar' gpeers $ M.delete PeerToDelete
        --TODO handle failures/exceptions/closed connections etc

randomIntervals :: GlobalData -> GlobalTVars -> IO ()
randomIntervals  gdata@GlobalData{..} gtv@GlobalTVars{..} = forever $ do
--    putStrLn $ "[" ++ show myPort ++ "] random Intervals"
    interval <- randomRIO(10,120)
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
    mapM_ (sendP gdata (Newtx (recent+offset))) $ M.toList peers

run ::  GlobalData -> HostName -> PortNumber ->  GlobalTVars -> IO ()
run gdata@GlobalData{..} seedHostName seedPort gtv@GlobalTVars{..} = do
    forkFinally (listen gdata gtv) (const $ putStrLn $ "I cannot listen on port: "++ show myPort)
    forkIO $ learnPeers gdata seedHostName seedPort 3 gtv -- 3 is the default
    forkFinally (randomIntervals gdata gtv) (const $ putStrLn "Random intervals ended unexpectedly")
    return ()
-- TODO connect to Node to find new peers on startup
-- Send Newtx 0 messages

clientThread :: GlobalData -> (Handle, HostName, PortNumber) -> GlobalTVars -> IO ()
clientThread gdata@GlobalData{..} (h, cHostName, cPort) gtv@GlobalTVars{..} = do
    putStrLn $ "Accepted connection from " ++ show cHostName ++ ":" ++ show cPort
    hSetNewlineMode h universalNewlineMode
    hSetBuffering h LineBuffering
    forever $ do
        msg <- hGetLine h
        processMessage gdata h cHostName gtv (read msg)

processMessage :: GlobalData -> Handle -> HostName -> GlobalTVars ->  Message -> IO ()
processMessage gdata@GlobalData{..} h cHostName gtv@GlobalTVars{..} = go
  where
    go (Status peers) = undefined
    go (Connect hostname port) = do
        atomically $ modifyTVar' gpeers $ M.insert (Peer hostname port) h
        return ()
    go GetPeers = do
        peers <- atomically $ readTVar gpeers -- ?
        send gdata (Status (M.keys peers)) h
    go (Newtx tx) = do
        maybeTx <- atomically $ processNewTx tx gtxs
        timestamp <- getCurrentTime
        appendFile logfile ("Tx #: " ++ show tx ++ " from " ++ cHostName ++ " " ++ show timestamp ++ "\n")
        case maybeTx of
            Nothing            -> propagateToPeers tx
            Just newestTxKnown -> send gdata (Oldtx newestTxKnown tx) h
    go Quit = do
        hClose h
        tid <- myThreadId
        killThread tid
    go (Unknown str) = do
        putStrLn "Error unknown message given"
        return ()
    go (Oldtx newtx _) = do
        atomically $ processNewTx newtx gtxs
        return ()

    propagateToPeers :: Tx -> IO ()
    propagateToPeers tx = do
        peers <- atomically $ readTVar gpeers
        let msg = Newtx tx
        del <- atomically $ readTVar delay
        threadDelay(del*second)
        mapM_ (sendP gdata  msg) $ M.toList peers

send :: GlobalData -> Message -> Handle -> IO ()
send gdata@GlobalData{..} msg h = do
    appendFile logMessages $ "[" ++ show myPort ++ "] -> [????]: " ++ show msg ++ "\n"
    hPrint h msg

sendP :: GlobalData -> Message -> (Peer,Handle) -> IO ()
sendP gdata@GlobalData{..} msg (Peer peerHost peerPort,h) = do
    appendFile logMessages $ "[" ++ show myPort ++ "] -> [" ++ show peerPort ++ "]: " ++ show msg ++ "\n"
    hPrint h msg

--TODO use chans for each peer (add to record) . Else just open a new connection
