{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GADTs             #-}
{-# LANGUAGE TypeFamilies      #-}
module Network.Haskoin.Wallet.Root 
( getWalletEntity
, getWallet
, walletList
, newWallet
, initWalletDB
) where

import Control.Monad (liftM, when)
import Control.Monad.Reader (ReaderT)
import Control.Exception (throwIO)
import Control.Monad.Trans (MonadIO, liftIO)

import Data.Maybe (fromJust, isJust, isNothing)
import Data.Time (getCurrentTime)
import qualified Data.ByteString as BS

import Database.Persist
    ( PersistUnique
    , PersistQuery
    , PersistStore
    , Entity(..)
    , getBy
    , insert_
    , selectList
    , selectFirst
    , entityVal
    , SelectOpt( Asc )
    )

import Network.Haskoin.Crypto
import Network.Haskoin.Wallet.Model
import Network.Haskoin.Wallet.Types

-- | Get a wallet by name
getWallet :: (MonadIO m, PersistStore b, PersistUnique b)
          => String -> ReaderT b m Wallet
getWallet name = liftM (dbWalletValue . entityVal) $ getWalletEntity name

getWalletEntity :: (MonadIO m, PersistStore b, PersistUnique b)
                => String -> ReaderT b m (Entity (DbWalletGeneric b))
getWalletEntity name = do
    entM <- getBy $ UniqueWalletName name
    case entM of
        Just ent -> return ent
        Nothing  -> liftIO $ throwIO $ WalletException $ 
            unwords ["Wallet", name, "does not exist"]

-- | Get a list of all the wallets
walletList :: (MonadIO m, PersistQuery b) => ReaderT b m [Wallet]
walletList = 
    liftM (map f) $ selectList [] [Asc DbWalletCreated]
  where
    f = dbWalletValue . entityVal

-- | Initialize a wallet from a secret seed. This function will fail if the
-- wallet is already initialized.
newWallet :: (MonadIO m, PersistQuery b, PersistUnique b)
          => String         -- ^ Wallet name
          -> BS.ByteString  -- ^ Secret seed
          -> ReaderT b m Wallet -- ^ New wallet
newWallet wname seed 
    | BS.null seed = liftIO $ throwIO $ 
        WalletException "The seed is empty"
    | otherwise = do
        prevWallet <- getBy $ UniqueWalletName wname
        when (isJust prevWallet) $ liftIO $ throwIO $ WalletException $
            unwords [ "Wallet", wname, "already exists" ]
        time <- liftIO getCurrentTime
        let master = makeMasterKey seed
            wallet = Wallet wname $ fromJust master
        -- This should never happen
        when (isNothing master) $ liftIO $ throwIO $ WalletException
            "The seed derivation produced an invalid key. Use another seed."
        insert_ $ DbWallet wname wallet Nothing time
        return wallet

initWalletDB :: (MonadIO m, PersistQuery b) => ReaderT b m ()
initWalletDB = do
    prevConfig <- selectFirst [] [Asc DbConfigCreated]
    when (isNothing prevConfig) $ do
        time <- liftIO getCurrentTime
        insert_ $ DbConfig 0 1 time

