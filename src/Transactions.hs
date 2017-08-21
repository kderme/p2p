{-# LANGUAGE RecordWildCards #-}
module Transactions where

import           Lib

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

newTransactions :: IO (TVar Transactions)
newTransactions = newTVarIO []

isNew :: Transactions -> Tx -> Bool
isNew [] tx     = True
isNew (x:xs) tx = tx > x

getNew :: Transactions -> Tx
getNew = head

processNewTx :: Tx -> TVar Transactions -> STM (Maybe Tx)
processNewTx newtx txs' = do
    txs <- readTVar txs'
    if isNew txs newtx
    then do
        writeTVar txs' (newtx:txs)
        return Nothing
    else
        return $ Just $ getNew txs
