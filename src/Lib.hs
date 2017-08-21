module Lib where

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

data GlobalData =
    GlobalData
        { myHostName   :: HostName
        , myPort       :: PortNumber
        , lockFile     :: MVar ()
        , logFile      :: FilePath
        , lockMessages :: MVar ()
        , logMessages  :: FilePath
        , delay        :: TVar Int
        , gpeers       :: TVar PeersDict
        , gtxs         :: TVar Transactions
        }

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

type Tx = Int
type Transactions = [Tx]

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

second :: Int
second = 1000000

trying :: String -> String
trying "_" = "127.0.0.1"
trying str = str

safeLog :: MVar () -> FilePath -> String -> IO ()
safeLog lock file str = do
  takeMVar lock
  appendFile file str
  putMVar lock ()

safeLogMsg :: MVar () -> FilePath -> Message -> PortNumber -> PortNumber -> IO ()
safeLogMsg lock file msg fromPort toPort =
  safeLog lock file str
    where
      str = "["++ show fromPort ++ "]" ++ "-->" ++ "["++ show toPort ++ "]: " ++ show msg ++ "\n"
