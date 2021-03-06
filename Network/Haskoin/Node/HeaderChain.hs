{-# LANGUAGE OverloadedStrings #-}
module Network.Haskoin.Node.HeaderChain
( LevelSession(..)
, DBHandle
, BlockHeaderNode(..)
, BlockHeaderAction(..)
, BlockChainAction(..)
, initDB
, getActionNode
, getBlockHeaderNode
, getBestBlock
, putBestBlock
, getBestHeader
, getFastCatchup
, setFastCatchup
, getLastDownload
, putLastDownload
, getParent
, addBlockHeader
, getDownloads
, addMerkleBlock
, blockLocator
, bestBlockHeight
, bestHeaderHeight
)
where

import Control.Monad (when, unless, foldM)
import Control.Applicative ((<$>), (<*>))
import Control.Monad.Trans (lift)
import Control.Monad.Trans.Either (left, runEitherT)
import qualified Control.Monad.State as S (StateT, gets)

import Data.Word (Word32)
import Data.List (sort, nub)
import Data.Bits (shiftR, shiftL)
import Data.Maybe (fromJust, isNothing, isJust)
import Data.Binary (Binary, get, put)
import Data.Binary.Get (getWord32le)
import Data.Binary.Put (putWord32le)
import Data.Default (def)
import qualified Data.ByteString as BS (ByteString, append, reverse)

import qualified Database.LevelDB.Base as DB 
    ( DB
    , get
    , put
    , write
    , BatchOp( Put )
    )

import Network.Haskoin.Node.Checkpoints
import Network.Haskoin.Crypto
import Network.Haskoin.Protocol
import Network.Haskoin.Util
import Network.Haskoin.Constants

-- | Lower bound for the proof of work difficulty
proofOfWorkLimit :: Integer
proofOfWorkLimit = fromIntegral (maxBound `shiftR` 32 :: Word256)

-- | Time between difficulty cycles (2 weeks on average)
targetTimespan :: Word32
targetTimespan = 14 * 24 * 60 * 60

-- | Time between blocks (10 minutes per block)
targetSpacing :: Word32
targetSpacing = 10 * 60

-- | Number of blocks on average between difficulty cycles (2016 blocks)
diffInterval :: Word32
diffInterval = targetTimespan `div` targetSpacing

data LevelSession = LevelSession { handle :: DB.DB }

type DBHandle = S.StateT LevelSession IO

-- Represent a node in the block header chain
data BlockHeaderNode 
    = BlockHeaderGenesis
        { nodeBlockHash    :: !BlockHash
        , nodeHeader       :: !BlockHeader
        , nodeHeaderHeight :: !Word32
        , nodeChainWork    :: !Integer
        , nodeChild        :: !(Maybe BlockHash)
        , nodeMedianTimes  :: ![Word32]
        -- Only used for testnet
        , nodeMinWork      :: !Word32
        }
    | BlockHeaderNode 
        { nodeBlockHash    :: !BlockHash
        , nodeHeader       :: !BlockHeader
        , nodeHeaderHeight :: !Word32
        , nodeChainWork    :: !Integer
        -- TODO: Remove this and use the parent field in nodeHeader
        , nodeParent       :: !BlockHash
        , nodeChild        :: !(Maybe BlockHash)
        , nodeMedianTimes  :: ![Word32]
        -- Only used for testnet
        , nodeMinWork      :: !Word32
        } deriving (Show, Read, Eq)

instance Binary BlockHeaderNode where

    get = go =<< get
      where
        genid = headerHash genesisHeader
        go i | i == genid = BlockHeaderGenesis i <$> get 
                                                 <*> getWord32le 
                                                 <*> get 
                                                 <*> get 
                                                 <*> get 
                                                 <*> get 
             | otherwise  = BlockHeaderNode i <$> get 
                                              <*> getWord32le 
                                              <*> get 
                                              <*> get
                                              <*> get
                                              <*> get
                                              <*> get

    put (BlockHeaderGenesis i b h w c t m) = do
        put i
        put b
        putWord32le h
        put w
        put c
        put t 
        put m
    put (BlockHeaderNode i b h w p c t m) = do
        put i 
        put b 
        putWord32le h 
        put w 
        put p 
        put c
        put t 
        put m

-- Return value of linking a new block header in the chain
-- TODO: Add more options if required
data BlockHeaderAction
    = RejectHeader String
    | HeaderAlreadyExists BlockHeaderNode
    | AcceptHeader BlockHeaderNode
    deriving (Show, Read, Eq)

data BlockChainAction
    = BestBlock  { actionBestBlock :: BlockHeaderNode }
    | SideBlock  { actionSideBlock :: BlockHeaderNode }
    | BlockReorg { reorgSplitPoint :: BlockHeaderNode
                 , reorgOldBlocks  :: [BlockHeaderNode]
                 , reorgNewBlocks  :: [BlockHeaderNode]
                 }
    deriving (Read, Show, Eq)

getActionNode :: BlockChainAction -> BlockHeaderNode
getActionNode a = case a of
    BestBlock n -> n
    SideBlock n -> n
    BlockReorg _ _ ns -> last ns

indexKey :: BlockHash -> BS.ByteString
indexKey h = "index_" `BS.append` encode' h

bestHeaderKey :: BS.ByteString
bestHeaderKey = "bestheader"

bestBlockKey :: BS.ByteString
bestBlockKey = "bestblock"

fastCatchupKey :: BS.ByteString
fastCatchupKey = "starttime"

lastDownloadKey :: BS.ByteString
lastDownloadKey = "lastdownload"

getBlockHeaderNode :: BlockHash -> DBHandle (Maybe BlockHeaderNode)
getBlockHeaderNode h = do
    db  <- S.gets handle
    res <- DB.get db def $ indexKey h
    return $ decodeToMaybe =<< res

putBlockHeaderNode :: BlockHeaderNode -> DBHandle ()
putBlockHeaderNode bhn = do
    db <- S.gets handle
    DB.put db def (indexKey $ nodeBlockHash bhn) $ encode' bhn

getBestBlock :: DBHandle BlockHeaderNode
getBestBlock = do
    db <- S.gets handle
    key <- decode' . fromJust <$> DB.get db def bestBlockKey
    fromJust <$> getBlockHeaderNode key

putBestBlock :: BlockHash -> DBHandle ()
putBestBlock h = do
    db <- S.gets handle
    DB.put db def bestBlockKey $ encode' h

getBestHeader :: DBHandle BlockHeaderNode
getBestHeader = do
    db  <- S.gets handle
    -- TODO: We assume the key always exists. Is this correct?
    key <- decode' . fromJust <$> DB.get db def bestHeaderKey
    fromJust <$> getBlockHeaderNode key

putBestHeader :: BlockHash -> DBHandle ()
putBestHeader h = do
    db <- S.gets handle
    DB.put db def bestHeaderKey $ encode' h

getFastCatchup :: DBHandle (Maybe Word32)
getFastCatchup = do
    db <- S.gets handle
    res <- DB.get db def fastCatchupKey
    return $ decode' <$> res

-- | Set the fast catchup time 
setFastCatchup :: Word32 -> DBHandle ()
setFastCatchup fstKeyTime = do
    db <- S.gets handle
    let -- Adjust time backwards by a week to handle clock drifts.
        fastCatchupI = max 0 ((toInteger fstKeyTime) - 86400 * 7)
        fastCatchup  = fromInteger fastCatchupI :: Word32
    -- Save the new fast catchup time
    DB.put db def fastCatchupKey $ encode' fastCatchup
    -- Find the position of the new best header and download pointer
    currentHead <- getBestHeader 
    bestBlock   <- findBestBlock fastCatchup currentHead
    putBestBlock $ nodeBlockHash bestBlock
    putLastDownload $ nodeBlockHash bestBlock
  where
    findBestBlock _ g@(BlockHeaderGenesis _ _ _ _ _ _ _) = return g
    findBestBlock fastCatchup n
        | blockTimestamp (nodeHeader n) < fastCatchup = 
            return n
        | otherwise = do
            par <- getParent n
            findBestBlock fastCatchup par

getLastDownload :: DBHandle BlockHeaderNode
getLastDownload = do
    db  <- S.gets handle
    -- TODO: We assume the key always exists. Is this correct?
    key <- decode' . fromJust <$> DB.get db def lastDownloadKey
    fromJust <$> getBlockHeaderNode key

putLastDownload :: BlockHash -> DBHandle ()
putLastDownload h = do
    db <- S.gets handle
    DB.put db def lastDownloadKey $ encode' h

-- Insert the genesis block if it is not already there
-- TODO: If dwnStart is not equal to the one in the database, issue a warning
-- or an error.
initDB :: DBHandle ()
initDB = S.gets handle >>= \db -> do
    prevGen <- getBlockHeaderNode genid
    when (isNothing prevGen) $ DB.write db def
        [ DB.Put (indexKey genid) $ encode' BlockHeaderGenesis
           { nodeBlockHash    = genid
           , nodeHeader       = genesisHeader
           , nodeHeaderHeight = 0
           , nodeChainWork    = headerWork genesisHeader
           , nodeChild        = Nothing
           , nodeMedianTimes  = [blockTimestamp genesisHeader]
           , nodeMinWork      = blockBits genesisHeader
           }
        , DB.Put bestHeaderKey   $ encode' genid
        , DB.Put bestBlockKey    $ encode' genid
        , DB.Put lastDownloadKey $ encode' genid
        ]
  where
    genid = headerHash genesisHeader

-- bitcoind function ProcessBlockHeader and AcceptBlockHeader in main.cpp
-- TODO: Add DOS return values
addBlockHeader :: BlockHeader -> Word32 -> DBHandle BlockHeaderAction
addBlockHeader bh adjustedTime = ((f <$>) . runEitherT) $ do
    unless (checkProofOfWork bh) $ 
        left $ RejectHeader "Invalid proof of work"
    unless (blockTimestamp bh <= adjustedTime + 2 * 60 * 60) $
        left $ RejectHeader "Invalid header timestamp"
    existsM <- lift $ getBlockHeaderNode bid
    unless (isNothing existsM) $
        left $ HeaderAlreadyExists $ fromJust existsM
    prevNodeM <- lift $ getBlockHeaderNode $ prevBlock bh
    let prevNode  = fromJust prevNodeM
    unless (isJust prevNodeM) $
        left $ RejectHeader "Previous block not found"
    nextWork <- lift $ getNextWorkRequired prevNode bh
    unless (blockBits bh == nextWork) $
        left $ RejectHeader "Incorrect work transition (bits)"
    let sortedMedians = sort $ nodeMedianTimes prevNode
        medianTime    = sortedMedians !! (length sortedMedians `div` 2)
    when (blockTimestamp bh <= medianTime) $
        left $ RejectHeader "Block timestamp is too early"
    chkPointM <- lift lastCheckpoint
    let chkPoint  = fromJust chkPointM
        newHeight = nodeHeaderHeight prevNode + 1
    unless (isNothing chkPointM || (fromIntegral newHeight) > fst chkPoint) $
        left $ RejectHeader "Rewriting pre-checkpoint chain"
    unless (verifyCheckpoint (fromIntegral newHeight) bid) $
        left $ RejectHeader "Rejected by checkpoint lock-in"
    -- All block of height 227836 or more use version 2 in prodnet
    -- TODO: Find out the value here for prodnet
    when (  networkName == "prodnet" 
         && blockVersion bh == 1 
         && nodeHeaderHeight prevNode + 1 >= 227836) $
        left $ RejectHeader "Rejected version=1 block"
    lift $ storeBlockHeader bh prevNode
  where
    f (Right x) = x
    f (Left  x) = x
    bid = headerHash bh

storeBlockHeader :: BlockHeader -> BlockHeaderNode 
                 -> DBHandle BlockHeaderAction
storeBlockHeader bh prevNode = do
    if allowMinDifficultyBlocks
        then do
            let isDiffChange = nodeHeaderHeight newNode `mod` diffInterval == 0
                isNotLimit   = blockBits (nodeHeader newNode) 
                               /= encodeCompact proofOfWorkLimit
                minWork | isDiffChange || isNotLimit = blockBits bh
                        | otherwise                  = nodeMinWork prevNode
            putBlockHeaderNode newNode{ nodeMinWork = minWork }
        else putBlockHeaderNode newNode
    putBlockHeaderNode $ prevNode{ nodeChild = Just $ nodeBlockHash newNode }
    currentHead <- getBestHeader
    when (nodeChainWork newNode > nodeChainWork currentHead) $ do
        putBestHeader bid
        -- Update the block head if we are before the fast catchup time
        -- By setting a new best block, we sort of flag it as downloaded
        fastCatchupM <- getFastCatchup
        let fastCatchup = fromJust fastCatchupM
            updateBest = 
                isJust fastCatchupM && 
                blockTimestamp (nodeHeader newNode) < fastCatchup
        when updateBest $ do
            putBestBlock bid
            putLastDownload bid
    return $ AcceptHeader newNode
  where
    bid       = headerHash bh
    newHeight = nodeHeaderHeight prevNode + 1
    newWork   = nodeChainWork prevNode + headerWork bh
    newMedian 
        | length (nodeMedianTimes prevNode) == 11 =
            tail (nodeMedianTimes prevNode) ++ [blockTimestamp bh]
        | otherwise = 
            (nodeMedianTimes prevNode) ++ [blockTimestamp bh]
    newNode   = BlockHeaderNode { nodeBlockHash    = bid
                                , nodeHeader       = bh
                                , nodeHeaderHeight = newHeight
                                , nodeChainWork    = newWork
                                , nodeParent       = prevBlock bh
                                , nodeChild        = Nothing
                                , nodeMedianTimes  = newMedian
                                , nodeMinWork      = 0
                                }

getDownloads :: Int -> Word32 -> DBHandle [BlockHash]
getDownloads count height = do
    fastCatchupM <- getFastCatchup
    if isNothing fastCatchupM then return [] else do
        n <- getLastDownload
        let minCount = min (fromIntegral count) (height - nodeHeaderHeight n)
        (res, lstDwn) <- go [] minCount n
        putLastDownload $ nodeBlockHash lstDwn
        return $ reverse res
  where
    go acc step n
        | step <= 0 = return (acc, n)
        | isNothing $ nodeChild n = do
            bestHead <- getBestHeader
            -- The pointer could be stuck in an orphaned fork
            if nodeChainWork bestHead > nodeChainWork n
                then do
                    (split,_,_) <- findSplit bestHead n
                    go ((nodeBlockHash split):acc) (step-1) split
                else return (acc, n)
        | otherwise = do
            c <- fromJust <$> (getBlockHeaderNode $ fromJust $ nodeChild n)
            go ((nodeBlockHash c):acc) (step-1) c 

-- bitcoind function GetNextWorkRequired in main.cpp
getNextWorkRequired :: BlockHeaderNode -> BlockHeader -> DBHandle Word32
getNextWorkRequired (BlockHeaderGenesis _ _ _ _ _ _ _) _ = 
    return $ encodeCompact proofOfWorkLimit
getNextWorkRequired lastNode bh
    -- Only change the difficulty once per interval
    | (nodeHeaderHeight lastNode + 1) `mod` diffInterval /= 0 = 
        if allowMinDifficultyBlocks then minWork else
            return $ blockBits $ nodeHeader lastNode
    | otherwise = do
        -- TODO: Can this break if there are not enough blocks in the chain?
        firstNode <- foldM (\x f -> f x) lastNode fs
        return $ getNewWork (nodeHeader firstNode) (nodeHeader lastNode)
  where
    fs    = replicate (fromIntegral diffInterval - 1) getParent
    delta =  targetSpacing * 2
    minWork
        | blockTimestamp bh > (blockTimestamp $ nodeHeader lastNode) + delta =
            return $ encodeCompact proofOfWorkLimit
        | otherwise = return $ nodeMinWork lastNode

-- | Given two block headers, compute the work required for the block following
-- the second block. The two input blocks should be spaced out by the number of
-- blocks between difficulty jumps (2016 in prodnet). 
getNewWork :: BlockHeader -> BlockHeader -> Word32
getNewWork firstB lastB
    | newDiff > proofOfWorkLimit = encodeCompact proofOfWorkLimit
    | otherwise                  = encodeCompact newDiff
  where
    t = fromIntegral $ (blockTimestamp lastB) - (blockTimestamp firstB)
    actualTime 
        | t < targetTimespan `div` 4 = targetTimespan `div` 4
        | t > targetTimespan * 4     = targetTimespan * 4
        | otherwise                  = t
    lastDiff = decodeCompact $ blockBits lastB
    newDiff = lastDiff * (toInteger actualTime) `div` (toInteger targetTimespan)

-- We assume the merkle block are sorted by ascending height
addMerkleBlock :: MerkleBlock -> DBHandle BlockChainAction
addMerkleBlock mb = do
    newNode   <- fromJust <$> getBlockHeaderNode bid
    chainHead <- getBestBlock
    if nodeParent newNode == nodeBlockHash chainHead
        -- We connect to the best chain
        then do
            putBestBlock bid
            return $ BestBlock newNode
        else if nodeChainWork newNode > nodeChainWork chainHead
                 then handleNewBestChain newNode chainHead
                 else return $ SideBlock newNode
  where
    bid = headerHash $ merkleHeader mb

handleNewBestChain :: BlockHeaderNode -> BlockHeaderNode 
                   -> DBHandle BlockChainAction
handleNewBestChain newChainHead oldChainHead = do
    (splitPoint, oldChain, newChain) <- findSplit oldChainHead newChainHead
    putBestBlock $ nodeBlockHash newChainHead
    return $ BlockReorg splitPoint oldChain newChain

-- | Find the split point between two nodes. It also returns the two partial
-- chains leading from the split point to the respective nodes.
findSplit :: BlockHeaderNode -> BlockHeaderNode 
          -> DBHandle (BlockHeaderNode, [BlockHeaderNode], [BlockHeaderNode])
findSplit n1 n2 = go [] [] n1 n2
  where
    go xs ys x y
        | nodeBlockHash x == nodeBlockHash y = return (x, x:xs, y:ys)
        | nodeHeaderHeight x > nodeHeaderHeight y = do
            par <- getParent x
            go (x:xs) ys par y
        | otherwise = do
            par <- getParent y
            go xs (y:ys) x par

-- This can fail if the node has no parent 
getParent :: BlockHeaderNode -> DBHandle BlockHeaderNode
getParent (BlockHeaderGenesis _ _ _ _ _ _ _) = 
    error "Genesis block has no parent"
getParent node = do
    bsM <- getBlockHeaderNode $ nodeParent node
    -- TODO: Throw exception instead of crashing fromJust
    return $ fromJust bsM

bestHeaderHeight :: DBHandle Word32
bestHeaderHeight = nodeHeaderHeight <$> getBestHeader

bestBlockHeight :: DBHandle Word32
bestBlockHeight = nodeHeaderHeight <$> getBestBlock

blockLocator :: DBHandle [BlockHash]
blockLocator = do
    h  <- getBestHeader
    let xs = [go ((2 :: Int)^x) | x <- ([0..] :: [Int])]
    ns <- f [h] $ replicate 10 (go (1 :: Int)) ++ xs
    return $ reverse $ nub $ genid : map nodeBlockHash ns
  where
    genid = headerHash genesisHeader
    f acc (g:gs) = g (head acc) >>= \resM -> case resM of
        Just res -> f (res:acc) gs
        Nothing  -> return acc
    f _ _ = undefined
    go _ (BlockHeaderGenesis _ _ _ _ _ _ _) = return Nothing
    go 0 n = return $ Just n
    go step n = go (step-1) =<< getParent n

-- Get the last checkpoint that we have seen
lastCheckpoint :: DBHandle (Maybe (Int, BlockHash))
lastCheckpoint = 
    foldM f Nothing $ reverse checkpointList
  where
    f res (i,chk) = if isJust res then return res else do
        haveChk <- getBlockHeaderNode chk
        return $ if isJust haveChk then Just (i,chk) else Nothing

-- Pure function

-- bitcoind function CheckProofOfWork in main.cpp
-- TODO: Return an error message?
checkProofOfWork :: BlockHeader -> Bool
checkProofOfWork bh
    | target <= 0 || target > proofOfWorkLimit = False
    | otherwise = getProofOfWork bh <= fromIntegral target
  where
    target = decodeCompact $ blockBits bh

getProofOfWork :: BlockHeader -> Integer
getProofOfWork =  bsToInteger . BS.reverse . encode' . headerHash

-- | Returns the work represented by this block. Work is defined as the number 
-- of tries needed to solve a block in the average case with respect to the
-- target.
headerWork :: BlockHeader -> Integer
headerWork bh = 
    largestHash `div` (target + 1)
  where
    target      = decodeCompact (blockBits bh)
    largestHash = 1 `shiftL` 256

