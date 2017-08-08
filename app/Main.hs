module Main where

import           Control.Concurrent
import           Control.Concurrent.STM
import           Control.Exception
import           Control.Monad
import           Data.List
import           Data.Time
import           Network
import qualified Network.HostName       as HH
import           System.Environment
import           System.IO
import           System.Random

import           Lib

-- Peer interface --

data Peer =
    Peer
        { hostName :: HostName
        , port     :: PortNumber
        } deriving (Show, Read,Eq)

type Peers = [Peer]
type PeersHandle = [(Peer, Handle)]

newPeers :: IO (TVar PeersHandle)
newPeers = newTVarIO []

-- End of Peer interface --

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

type Args = (PortNumber,HostName,PortNumber,Int)

data InterMsg =
    Run Args
    | Listen PortNumber Int
    | LearnPeers PortNumber HostName PortNumber
    | ShowTxs
    | ShowPeers
    deriving (Show, Read)

main :: IO ()
main = do
  gpeers <- newPeers --global Peers TVar
  gtxs <- newTransactions --global Transactions TVar
  let gtv = GlobalTVars gpeers gtxs
  forever $ do
      line <- getLine
      let command = read line
      case command of
          Run args    -> void $ run gtv args
          Listen port delay -> void $ listen gtv port "log_txos" delay
          LearnPeers myport hostName port -> void $ learnPeers myport gtv hostName port
          ShowPeers    -> atomically (readTVar gpeers) >>= print
          ShowTxs    -> atomically (readTVar gtxs) >>= print
  return ()


learnPeers :: PortNumber -> GlobalTVars -> HostName -> PortNumber -> IO ()
learnPeers myport gtv@(GlobalTVars gpeers gtxs) hostName cport = do
    l <- go 10 [] hostName cport
    first <- RandomRIO(1,10)
    second <- RandomRIO(1,10)
    third <- RandomRIO(1,10)

    return ()
    where
        go n possible_conn hostName cport
            | n < 0     = return possible_conn
            | otherwise = do
                h <- connectTo hostName $ PortNumber cport
                myhost <- HH.getHostName
                hPrint h GetPeers
                answer <- hGetLine h
                let Status p = read answer
                let (Peer nexthost nextport) = head p
                hClose h
                go (n-length p) (possible_conn ++ p) nexthost nextport


listen :: GlobalTVars -> PortNumber -> FilePath -> Int -> IO ThreadId
listen gtv@(GlobalTVars gpeers gtxs) port logfile delay = forkIO $ do
    s   <- listenOn (PortNumber port)
    forever $ do
        hhp <- accept s
        forkIO $ clientThread gtv hhp logfile delay
--TODO handle failures/exceptions/closed connections etc

randomIntervals :: TVar PeersHandle -> TVar Transactions -> FilePath -> IO ThreadId
randomIntervals gpeers gtxs logfile = forkIO $ forever $ do
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
    mapM_ (send (Newtx (recent+offset))) peers

run :: GlobalTVars -> Args -> IO ThreadId
run gtv@(GlobalTVars gpeers gtxs) args = forkIO $ do
    let (port,seedIp,seedPort,delay) = args
        logfile = "txos_log"
    learnPeers port gtv seedIp seedPort
    randomIntervals gpeers gtxs logfile
    s <- listenOn (PortNumber port)
    putStrLn $ "Listening on port " ++ show port
--TODO connect to Node to find new peers on startup
--Send Newtx 0 messages

clientThread :: GlobalTVars -> (Handle, HostName, PortNumber) ->  FilePath -> Int -> IO ()
clientThread gtv@(GlobalTVars gpeers gtxs) (h, chost, cport)  logfile delay = do
    putStrLn $ "Accepted connection from " ++ show chost ++ ":" ++ show cport
    hSetNewlineMode h universalNewlineMode
    hSetBuffering h LineBuffering
    forever $ do
        msg <- hGetLine h
        processMessage h chost gtv logfile delay (read msg)

processMessage :: Handle -> HostName -> GlobalTVars -> FilePath -> Int -> Message -> IO ()
processMessage h chost gtv@(GlobalTVars gpeers gtxs) logfile delay = go
  where
    go (Status peers) = undefined
    go (Connect host port) = do
        atomically $ modifyTVar' gpeers (\old -> (Peer host port,h):old)
        return ()
    go GetPeers = do
        p <- atomically $ readTVar gpeers -- ?
        hPrint h (Status (map fst p))
    go (Newtx tx) = do
        maybeTx <- atomically $ processNewTx tx gtxs
        timestamp <- getCurrentTime
        appendFile logfile ("Tx #: " ++ show tx ++ " from " ++ chost ++ " " ++ show timestamp ++ "\n")
        case maybeTx of
            Nothing            -> propagateToPeers tx
            Just newestTxKnown -> hPrint h (Oldtx newestTxKnown tx)
    go Quit = do
        hClose h
        tid <- myThreadId
        killThread tid
    go (Unknown str) = do
        putStrLn "Error unknown message given"
        return ()
    go (Oldtx _ _) = return ()

    propagateToPeers :: Tx -> IO ()
    propagateToPeers tx = do
        peers <- atomically $ readTVar gpeers
        let msg = Newtx tx
        threadDelay(delay*second)
        mapM_ (send msg) peers

send :: Message -> (Peer,Handle) -> IO ()
send msg (_,h) = hPrint h msg  --TODO use chans for each peer (add to record) . Else just open a new connection
