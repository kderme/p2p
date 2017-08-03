module Main where

import System.Environment
import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception
import Control.Monad

import Network
import System.IO


import Lib

data Peer = Peer HostName PortNumber deriving (Read, Show)

type Tx = Int

data Message =
    Connect HostName PortNumber
  | GetPeers
  | Status [Peer]
  | Newtx Tx
  | Oldtx Tx Tx
  | Quit
  | Unknown String
  deriving (Read, Show)


newPeers :: IO (TVar [Peer])
newPeers = do
  p <- newTVarIO []
  return p

main :: IO ()
main = do
  peers <- newPeers
  args <- getArgs
  let ip = head
      port = read $ head $ tail args
  s <- listenOn (PortNumber port)
  putStrLn $ "Listening on port " ++ show port
  forever $ do
    hhp <- accept s
    forkIO $ clientThread hhp peers


clientThread ::(Handle, HostName, PortNumber) -> TVar [Peer] -> IO ()
clientThread (h, chost, cport) peers = do 
  putStrLn $ "Accepted connection from " ++ show chost ++ ":" ++ show cport
  hSetNewlineMode h universalNewlineMode
  hSetBuffering h LineBuffering
  forever $ do
    msg <- hGetLine h
    dosth h peers $ read msg

dosth :: Handle -> TVar [Peer] -> Message -> IO ()
dosth h peers = go
  where
    go (Connect host port) = do
      atomically $ modifyTVar' peers (\old -> (Peer host port):old)
      return ()
    go GetPeers = do
      p <- atomically $ readTVar peers -- ?
      hPutStrLn h $ show $ Status p
    go (Newtx tx) = error ""


