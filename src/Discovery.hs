{-# LANGUAGE RecordWildCards #-}
module Discovery where

import           Lib
import           Message

import           Control.Concurrent
import           Control.Monad
import           Network
import           System.IO
-- import           System.Random

-- | A helper function that rejects every incoming message
-- until Status message comes.
waitStatus :: Handle -> IO Peers
waitStatus h = do
    answer <- hGetLine h
    case read answer of
      Status p -> return p
      _        -> waitStatus h

-- | This function fistly connects the corresponding Peer
-- to the given seed node and asks for its peers.
-- On receiving the peers, connects to these and asks them
-- for their peers as well, until there is no way of
-- finding new peers anymore, or reaches at least knowledge
-- of a certain number of possible peers.
-- Finally, it will randomly pick a given number out of
-- these and connect to them.
learnPeers :: GlobalData -> HostName -> PortNumber -> Int -> IO ()
learnPeers gdata@GlobalData{..} seedHostName seedPort target = do
    putStrLn $ "Entering learnPeers | " ++ seedHostName ++ ":" ++ show seedPort
    l <- go (3*target+1) [] [] seedHostName seedPort -- for num==3, 3n+1==10 .
    putStr "learnPeers | found peers: "
    print l
    let l3 = take (min target (length l)) l -- picks the peers to which will connect
    print l3
    -- threadDelay (5*second)
    mapM_ (\(Peer host port) -> forkFinally (void $ connectToPeer gdata host port)
        (const $ putStrLn "CONNECT_TO_PEER RETURNED") ) l3 -- connects to the list of selected peers
      where
        go n possible_conn connected hostname cport
            | n < 0     = return $ possible_conn ++ connected
            | otherwise = do
                h <- connectTo hostname $ PortNumber cport
                send gdata (Connect myHostName myPort) h
                send gdata GetPeers h
                p' <- waitStatus h -- waits for the peers of the other
                send gdata Quit h  -- sends Quit message to the other
                hClose h           -- closes the handle
                let
                  p = filter (\ s -> s /= Peer myHostName myPort) p' -- filters out himself of other's peers
                  newPossible = p ++ possible_conn
                  newConnected = Peer hostname cport : connected
                  (newN,nextHost,nextPort,possible) = case newPossible of
                    [] -> (-1,hostname,cport,[])
                    Peer host port:ls  -> (n - length p, host ,port,ls)
                go newN possible newConnected nextHost nextPort
