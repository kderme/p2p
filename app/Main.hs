{-# LANGUAGE RecordWildCards #-}

module Main where

import System.Environment
import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception
import Control.Monad

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
isNew [] tx = False
isNew (x:xs) tx = tx == x

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

main :: IO ()
main = do
    gpeers <- newPeers --global Peers TVar
    gtxs <- newTransactions --global Transactions TVar
    newTransactions 
    args <- getArgs
    let port = read $ head args
        seedIp = head $ tail args
        seedPort = read $ head $ tail $ tail args
    forkIO $ startUpThread seedIp $ PortNumber seedPort 
    forkIO $ randomIntervals gpeers gtxs
    s <- listenOn (PortNumber port)
    putStrLn $ "Listening on port " ++ show port
    forever $ do
        hhp <- accept s
        forkIO $ clientThread hhp gpeers gtxs --TODO handle failures/exceptions/closed connections etc

startUpThread :: HostName -> PortID -> IO ()
startUpThread h cport = undefined 
--TODO connect to Node to find new peers on startup
--Send Newtx 0 messages

randomIntervals :: TVar Peers -> TVar Transactions -> IO () 
randomIntervals gpeers gtxs = undefined -- TODO wake up every 10s to create new txs

clientThread :: (Handle, HostName, PortNumber) -> TVar Peers -> TVar Transactions -> IO ()
clientThread (h, chost, cport) peers txs = do 
    putStrLn $ "Accepted connection from " ++ show chost ++ ":" ++ show cport
    hSetNewlineMode h universalNewlineMode
    hSetBuffering h LineBuffering
    forever $ do
        msg <- hGetLine h
        processMessage h peers txs $ read msg

processMessage :: Handle -> TVar Peers -> TVar Transactions -> Message -> IO ()
processMessage h gpeers gtxs = go
  where
    go (Connect host port) = do
        atomically $ modifyTVar' gpeers (\old -> Peer host port:old)
        return ()
    go GetPeers = do
        p <- atomically $ readTVar gpeers -- ?
        hPutStrLn h $ show $ Status p
    go (Newtx tx) = do
        maybeTx <- atomically $ processNewTx tx gtxs
        case maybeTx of
            Nothing -> propagateToPeers tx --TODO log
            Just newestTxKnown -> hPutStrLn h $ show $ Oldtx newestTxKnown tx
    go Quit = error "Quit Message uniplemented" -- TODO
    go (Unknown str) = do
        putStrLn "Error unknown message given"
        return () -- TODO
    
    propagateToPeers :: Tx -> IO () 
    propagateToPeers tx = do
        peers <- atomically $ readTVar gpeers
        let msg = Newtx tx
        mapM_ (send msg) peers -- TODO Add delays between send


send :: Message -> Peer -> IO ()
send msg Peer{..} = undefined --TODO use chans for each peer (add to record) . Else just open a new connection
  
  

