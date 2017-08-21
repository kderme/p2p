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

learnPeers :: GlobalData -> HostName -> PortNumber -> Int -> IO ()
learnPeers gdata@GlobalData{..} seedHostName seedPort target = do
    putStrLn $ "Entering learnPeers | " ++ seedHostName ++ show seedPort
    l <- go (3*target+1) [] seedHostName seedPort -- for num==3, 3n+1==10 .
    let l3 = take (min target (length l)) l
    mapM_ (\(Peer host port) -> forkIO (void $ connectToPeer gdata host port)) l3
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