{-# LANGUAGE RecordWildCards #-}

module Main where

import System.Environment
import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception
import Control.Monad
import Data.Time
import System.Random
import Network
import System.IO

import Lib

-- Peer interface --

data Peer =
    Peer
        { hostName :: HostName
        , port     :: PortNumber
        }
    deriving (Read, Show)

type Peers = [Peer]

newPeers :: IO (TVar Peers)
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

-- Transactions Interface --

type Tx = Int
type Transactions = [Tx]
newTransactions :: IO (TVar Transactions)
newTransactions = newTVarIO []

isNew :: Transactions -> Tx -> Bool
isNew [] tx = True
isNew (x:xs) tx
    | tx > x    = True
    | otherwise = False

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

main :: IO ()
main = do
    gpeers <- newPeers --global Peers TVar
    gtxs <- newTransactions --global Transactions TVar
    newTransactions
    args <- getArgs
    let port = read $ head args
        seedIp = head $ tail args
        seedPort = read $ head $ tail $ tail args
        delay = read $ head $ tail $ tail $ tail args
        logfile = "txos_log"
    forkIO $ startUpThread seedIp $ PortNumber seedPort
    forkIO $ randomIntervals gpeers gtxs logfile
    s <- listenOn (PortNumber port)
    putStrLn $ "Listening on port " ++ show port
    forever $ do
        hhp <- accept s
        forkIO $ clientThread hhp gpeers logfile delay gtxs --TODO handle failures/exceptions/closed connections etc

startUpThread :: HostName -> PortID -> IO ()
startUpThread h cport = undefined
--TODO connect to Node to find new peers on startup
--Send Newtx 0 messages

randomIntervals :: TVar Peers -> TVar Transactions -> FilePath -> IO ()
randomIntervals gpeers gtxs logfile = forever $ do
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


clientThread :: (Handle, HostName, PortNumber) -> TVar Peers -> FilePath -> Int -> TVar Transactions -> IO ()
clientThread (h, chost, cport) peers logfile delay txs = do
    putStrLn $ "Accepted connection from " ++ show chost ++ ":" ++ show cport
    hSetNewlineMode h universalNewlineMode
    hSetBuffering h LineBuffering
    forever $ do
        msg <- hGetLine h
        processMessage h chost peers txs logfile delay (read msg)

processMessage :: Handle -> HostName -> TVar Peers -> TVar Transactions -> FilePath -> Int -> Message -> IO ()
processMessage h chost gpeers gtxs logfile delay  = go
  where
    go (Connect host port) = do
        atomically $ modifyTVar' gpeers (\old -> Peer host port:old)
        return ()
    go GetPeers = do
        p <- atomically $ readTVar gpeers -- ?
        hPrint h (Status p)
    go (Newtx tx) = do
        maybeTx <- atomically $ processNewTx tx gtxs
        timestamp <- getCurrentTime
        appendFile logfile ("Tx #: " ++ show tx ++ " from " ++ chost ++ " " ++ show timestamp ++ "\n")
        case maybeTx of
            Nothing -> propagateToPeers tx --TODO log
            Just newestTxKnown -> hPrint h (Oldtx newestTxKnown tx)
    go Quit = error "Quit Message uniplemented" -- TODO
    go (Unknown str) = do
        putStrLn "Error unknown message given"
        return () -- TODO

    propagateToPeers :: Tx -> IO ()
    propagateToPeers tx = do
        peers <- atomically $ readTVar gpeers
        let msg = Newtx tx
        --putStrLn "I will wait"
        threadDelay(delay*second)
        --putStrLn "I waited"
        mapM_ (send msg) peers -- TODO Add delays between send


send :: Message -> Peer -> IO ()
send msg Peer{..} = error "send is not implemented yet" --TODO use chans for each peer (add to record) . Else just open a new connection