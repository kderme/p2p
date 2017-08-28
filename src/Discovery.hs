{-# LANGUAGE RecordWildCards #-}
module Discovery where

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

waitStatus :: Handle -> IO Peers
waitStatus h = do
    answer <- hGetLine h
    case read answer of
      Status p -> return p
      _        -> waitStatus h

learnPeers :: GlobalData -> HostName -> PortNumber -> Int -> IO ()
learnPeers gdata@GlobalData{..} seedHostName seedPort target = do
    putStrLn $ "Entering learnPeers | " ++ seedHostName ++ show seedPort
    l <- go (3*target+1) [] [] seedHostName seedPort -- for num==3, 3n+1==10 .
    putStr "learnPeers | found peers: "
    print l
    let l3 = take (min target (length l)) l
    print l3
    threadDelay (5*second)
    mapM_ (\(Peer host port) -> forkFinally (void $ connectToPeer gdata host port)
        (const $ putStrLn "CONNECT_TO_PEER RETURNED") ) l3
      where
        go n possible_conn connected hostname cport
            | n < 0     = return $ possible_conn ++ connected
            | otherwise = do
                h <- connectTo hostname $ PortNumber cport
                send gdata (Connect myHostName myPort) h
                send gdata GetPeers h
                p' <- waitStatus h
                send gdata Quit h
                hClose h
                let
                  p = filter (\ s -> s /= Peer myHostName myPort) p'
                  newPossible = p ++ possible_conn
                  newConnected = Peer hostname cport : connected
                  (newN,nextHost,nextPort,possible) = case newPossible of
                    [] -> (-1,hostname,cport,[])
                    Peer host port:ls  -> (n - length p, host ,port,ls)
                go newN possible newConnected nextHost nextPort
