{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

module Kontiki.State.Persistent (
      PersistentStateT
    , runPersistentStateT
    ) where

import GHC.Generics (Generic)

import Control.Monad.IO.Class (MonadIO)
import Control.Monad.Reader.Class (MonadReader(ask, local))
import Control.Monad.Trans.Class (MonadTrans, lift)
import Control.Monad.Trans.Reader (ReaderT, mapReaderT, runReaderT)

import Control.Monad.Logger (MonadLogger)
import Katip (Katip, KatipContext)

import Control.Monad.Base (MonadBase)
import Control.Monad.Catch (Exception, MonadCatch, MonadMask, MonadThrow, throwM)

import Control.Monad.Trans.Control (
    ComposeSt,
    MonadBaseControl(StM, liftBaseWith, restoreM) , defaultLiftBaseWith, defaultRestoreM,
    MonadTransControl(StT, liftWith, restoreT), defaultLiftWith, defaultRestoreT)

import Data.Default (def)

import qualified Data.ByteString.Char8 as BS8
import qualified Data.ByteString.Lazy as BS

import qualified Database.LevelDB as L

import qualified Proto3.Suite.Class as Proto3

import Control.Monad.Metrics (MonadMetrics)
import qualified Control.Monad.Metrics as Metrics

import Kontiki.Raft.Classes.RPC (MonadRPC)
import qualified Kontiki.Raft.Classes.RPC as RPC
import Kontiki.Raft.Classes.State.Persistent
    (MonadPersistentState(Term, Node, Entry, Index,
                          getCurrentTerm, setCurrentTerm,
                          getVotedFor, setVotedFor,
                          getLogEntry, setLogEntry,
                          lastLogEntry))
import Kontiki.Raft.Classes.Timers (MonadTimers)

import qualified Kontiki.Protocol.Types as T

newtype PersistentStateT m a = PersistentStateT { unPersistentStateT :: ReaderT L.DB m a }
    deriving {- stock -} (Functor
    {- deriving newtype ( -} , Applicative, Monad, MonadTrans, MonadIO, Katip, KatipContext, MonadBase b
    {- deriving anyclass ( -} , MonadLogger, MonadTimers, MonadCatch, MonadMask, MonadThrow)

instance MonadTransControl PersistentStateT where
    type StT PersistentStateT a = StT (ReaderT L.DB) a
    liftWith = defaultLiftWith PersistentStateT unPersistentStateT
    restoreT = defaultRestoreT PersistentStateT

instance MonadBaseControl b m => MonadBaseControl b (PersistentStateT m) where
    type StM (PersistentStateT m) a = ComposeSt PersistentStateT m a
    liftBaseWith = defaultLiftBaseWith
    restoreM = defaultRestoreM

runPersistentStateT :: L.DB -> PersistentStateT m a -> m a
runPersistentStateT db = flip runReaderT db . unPersistentStateT

mapPersistentStateT :: (m a -> n b) -> PersistentStateT m a -> PersistentStateT n b
mapPersistentStateT f = PersistentStateT . mapReaderT f . unPersistentStateT

currentTermKey, votedForKey :: BS8.ByteString
currentTermKey = BS8.pack "currentTerm"
votedForKey = BS8.pack "votedFor"

instance (Monad m, MonadIO m, MonadThrow m, MonadMetrics m) => MonadPersistentState (PersistentStateT m) where
    type Term (PersistentStateT m) = T.Term
    type Node (PersistentStateT m) = T.Node
    type Entry (PersistentStateT m) = T.Entry
    type Index (PersistentStateT m) = T.Index

    getCurrentTerm = doGet currentTermKey
    setCurrentTerm = doPut currentTermKey

    getVotedFor = unMaybeNode <$> doGet votedForKey
    setVotedFor = doPut votedForKey . maybeNode

    getLogEntry = error "Not implemented"
    setLogEntry = error "Not implemented"
    lastLogEntry = return Nothing --error "Not implemented"

instance (Monad m, MonadRPC m) => MonadRPC (PersistentStateT m) where
    type Node (PersistentStateT m) = RPC.Node m
    type RequestVoteRequest (PersistentStateT m) = RPC.RequestVoteRequest m
    type AppendEntriesRequest (PersistentStateT m) = RPC.AppendEntriesRequest m

instance MonadReader r m => MonadReader r (PersistentStateT m) where
    ask = lift ask
    local = mapPersistentStateT . local

data MaybeNode = MaybeNode { maybeNodeIsNull :: !Bool
                           , maybeNodeNode :: {-# UNPACK #-} !T.Node
                           }
    deriving (Show, Eq, Generic)

instance Proto3.Message MaybeNode
instance Proto3.Named MaybeNode

maybeNode :: Maybe T.Node -> MaybeNode
maybeNode = maybe (MaybeNode True def) (MaybeNode False)

unMaybeNode :: MaybeNode -> Maybe T.Node
unMaybeNode mn = if maybeNodeIsNull mn then Nothing else Just (maybeNodeNode mn)

newtype InitializationError = InitializationError String
    deriving (Show, Eq)
instance Exception InitializationError

doGet :: (Proto3.Message a, MonadIO m, MonadThrow m, MonadMetrics m)
      => BS8.ByteString
      -> PersistentStateT m a
doGet key = PersistentStateT $ Metrics.timed' Metrics.Milliseconds "kontiki.db.get" $ do
    db <- ask
    L.get db L.defaultReadOptions key >>= \case
        Nothing -> throwM $ InitializationError $ "Database not properly initialized: key " ++ show key ++ " not found"
        Just v -> either throwM return $ Proto3.fromByteString v

doPut :: (Proto3.Message a, MonadIO m, MonadMetrics m)
      => BS8.ByteString
      -> a
      -> PersistentStateT m ()
doPut key a = PersistentStateT $ Metrics.timed' Metrics.Milliseconds "kontiki.db.put" $ do
    db <- ask
    L.put db L.defaultWriteOptions key (BS.toStrict $ Proto3.toLazyByteString a)
