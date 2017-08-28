{-# LANGUAGE RecordWildCards #-}
module Discovery where

import           Lib
import           Message

import           Control.Concurrent
import           Control.Monad
import           Data.Array.IO
import qualified Data.Set as S
import           Network
import           System.IO
import           System.Random

-- | A helper function that rejects every incoming message
-- until Status message comes.
waitStatus :: Handle -> IO Peers
waitStatus h = do
    putStrLn "Entering waitStatus"
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
    set <- go (3*target+1) S.empty S.empty seedHostName seedPort -- for num==3, 3n+1==10 .
    let l = S.toList set
    putStr "learnPeers | found peers: "
    print l
    lRandom <- shuffle l
    let l3 = take (min target (length lRandom)) lRandom -- picks the peers to which will connect
    putStr "learnPeers | selected peers: "
    print l3
    threadDelay (3*second)
    mapM_ (\(Peer host port) -> forkFinally (void $ connectToPeer gdata host port)
        (const $ putStrLn "CONNECT_TO_PEER RETURNED") ) l3 -- connects to the list of selected peers
      where
        go n possible_conn connected hostname cport
            | n < 0     = return $ possible_conn `S.union` connected
            | otherwise = do
                h <- connectTo hostname $ PortNumber cport
                -- hSetNewlineMode h universalNewlineMode
                -- hSetBuffering h LineBuffering
                -- threadDelay (2*second)
                send gdata (Connect myHostName myPort) h
                send gdata GetPeers h
                p' <- waitStatus h -- waits for the peers of the other
                send gdata Quit h  -- sends Quit message to the other
                hClose h           -- closes the handle
                let
                  p = filter (\ s -> s /= Peer myHostName myPort) p'
                  -- filters out himself of other's peers
                  newPossible = (S.fromList p `S.union` possible_conn) `S.difference` connected
                  -- filters out already connected peers
                  newConnected = S.insert (Peer hostname cport) connected
                  (newN,nextHost,nextPort,possible) = case S.minView newPossible of
                    Just (Peer host port,rest)  -> (n - length p, host ,port,rest)
                    Nothing -> (-1,hostname,cport,S.empty)
                go newN possible newConnected nextHost nextPort

-- | A helper function that randomly shuffles a list
shuffle :: [a] -> IO [a]
shuffle xs = do
        ar <- newArr n' xs
        forM [1..n'] $ \i -> do
            j <- randomRIO (i,n')
            vi <- readArray ar i
            vj <- readArray ar j
            writeArray ar j vi
            return vj
    where
    n' = length xs
    newArr :: Int -> [a] -> IO (IOArray Int a)
    newArr i = newListArray (1, i)