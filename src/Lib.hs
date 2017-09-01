module Lib where

import           Control.Concurrent
import           Control.Concurrent.STM
import qualified Data.Map as M
import           Network
import           System.IO

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
        , pong       :: TVar Bool
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

-- | A second = 1.000.000 us
second :: Int
second = 1000000

-- | A helper function that if the given string is "_"
-- then it outputs localhost address.
trying :: String -> String
trying "_" = "127.0.0.1"
trying str = str

-- | A helper function that appends a string to a file
-- after taking the lock.
safeLog :: MVar () -> FilePath -> String -> IO ()
safeLog lock file str = do
  takeMVar lock
  appendFile file str
  putMVar lock ()

-- | A helper function that writes the message, the sender,
-- and the receiver to a file after taking the lock.
safeLogMsg :: MVar () -> FilePath -> Message -> PortNumber -> PortNumber -> IO ()
safeLogMsg lock file msg fromPort toPort =
  safeLog lock file str
    where
      str = "["++ show fromPort ++ "]" ++ "-->" ++ "["++ show toPort ++ "]: " ++ show msg ++ "\n"
