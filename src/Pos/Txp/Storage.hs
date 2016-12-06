{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE Rank2Types            #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TupleSections         #-}
{-# LANGUAGE ViewPatterns          #-}

-- | Internal state of the transaction-handling worker. Trasnaction
-- processing logic.

module Pos.Txp.Storage
       (
         TxStorage (..)
       , HasTxStorage (txStorage)
       , txStorageFromUtxo

       , getUtxoByDepth
       , getUtxo
       , isTxVerified
       , txVerifyBlocks
       , txApplyBlocks
       , txRollback
       , processTx
       ) where

import           Control.Lens            (ix, makeClassy, preview, use, uses, view, (%=),
                                          (.=), (<&>), (<~), (^.))
import qualified Data.List.NonEmpty      as NE
import           Data.SafeCopy           (base, deriveSafeCopySimple)
import           Formatting              (build, int, sformat, (%))
import           Serokell.Util           (VerificationRes (..))
import           Universum

import           Pos.Constants           (k)
import           Pos.Crypto              (WithHash (..), withHash)
import           Pos.State.Storage.Types (AltChain)
import           Pos.Types               (Block, SlotId, Tx (..), Utxo, applyTxToUtxo,
                                          blockSlot, blockTxs, normalizeTxs, slotIdF,
                                          verifyAndApplyTxs, verifyTxUtxo)

-- | Transaction-related state part, includes transactions, utxo and
-- auxiliary structures needed for transaction processing.
data TxStorage = TxStorage
    {
      -- | History of utxo. May be necessary in case of
      -- reorganization. Also it is needed for MPC. Head of this list
      -- is utxo corresponding to last known block.
      _txUtxoHistory :: ![Utxo]
    , -- | Set of unspent transaction outputs formed by applying
      -- txLocalTxs to the head of txUtxoHistory. It is need to check
      -- new transactions and run follow-the-satoshi, for example.
      _txUtxo        :: !Utxo
    }

-- | Generate TxStorage from non-default utxo.
txStorageFromUtxo :: Utxo -> TxStorage
txStorageFromUtxo u = TxStorage [u] u

-- | Classy lens generated for 'TxStorage'
makeClassy ''TxStorage
deriveSafeCopySimple 0 'base ''TxStorage

type Query a = forall m x. (HasTxStorage x, MonadReader x m) => m a

-- | Applies transaction to current utxo. Should be called only if
-- it's possible to do so (see 'verifyTx').
applyTx :: WithHash Tx -> Update ()
applyTx tx = txUtxo %= applyTxToUtxo tx

-- | Given number of blocks to rollback and some sidechain to adopt it
-- checks if it can be done prior to transaction validity. Returns a
-- list of topsorted transactions, head ~ deepest block on success.
txVerifyBlocks :: Word -> AltChain ssc -> Query (Either Text [[WithHash Tx]])
txVerifyBlocks (fromIntegral -> toRollback) newChain = do
    (preview (txUtxoHistory . ix toRollback)) <&> \case
        Nothing ->
            Left $ sformat ("Can't rollback on "%int%" blocks") toRollback
        Just utxo -> reverse . snd <$> foldM verifyDo (utxo, []) newChainTxs
  where
    newChainTxs :: [(SlotId,[WithHash Tx])]
    newChainTxs =
        fmap (\b -> (b ^. blockSlot, fmap withHash $ toList $ b ^. blockTxs)) . rights $
        NE.toList newChain
    verifyDo :: (Utxo,[[WithHash Tx]]) -> (SlotId, [WithHash Tx]) -> Either Text (Utxo, [[WithHash Tx]])
    verifyDo (utxo,accTxs) (slotId, txs) =
        case verifyAndApplyTxs txs utxo of
          Left reason        -> Left $ sformat eFormat slotId reason
          Right (txs',utxo') -> Right (utxo',txs':accTxs)
    eFormat =
        "Failed to apply transactions on block from slot " %
        slotIdF%", error: "%build

getUtxo :: Query Utxo
getUtxo = view txUtxo

-- | Get utxo corresponding to state right after block with given
-- depth has been applied.
getUtxoByDepth :: Word -> Query (Maybe Utxo)
getUtxoByDepth (fromIntegral -> depth) = preview $ txUtxoHistory . ix depth

-- | Check if given transaction is verified, e. g.
-- is present in `k` and more blocks deeper
isTxVerified :: Tx -> Query Bool
isTxVerified tx = do
    mutxo <- getUtxoByDepth k
    case mutxo of
        Nothing   -> pure False
        Just utxo -> case verifyTxUtxo utxo tx of
            VerSuccess   -> pure True
            VerFailure _ -> pure False

type Update a = forall m x. (HasTxStorage x, MonadState x m) => m a

-- | Apply chain of /definitely/ valid blocks which go right after
-- last applied block. If invalid block is passed, this function will
-- panic.
txApplyBlocks :: [WithHash Tx] -> AltChain ssc -> Update ()
txApplyBlocks localTxs blocks = do
    verdict <- runReaderT (txVerifyBlocks 0 blocks) =<< use txStorage
    case verdict of
        -- TODO Consider using `MonadError` and throwing `InternalError`.
        Left _ -> panic "Attempted to apply blocks that don't pass txVerifyBlocks"
        Right txs -> do
            -- Reset utxo to the last block's utxo. Doesn't change
            -- localTxs
            resetLocalUtxo
            -- Apply all the blocks' transactions
            mapM_ txApplyBlock (NE.toList blocks `zip` txs)
            -- It also can be that both transaction X ∈ localStorage
            -- and Y ∈ block spend output A, so we must filter local
            -- transactions that became invalid after block
            -- application and regenerate local utxo with them
            overrideWithLocalTxs localTxs

txApplyBlock :: (Block ssc, [WithHash Tx]) -> Update ()
txApplyBlock (b, txs) = do
    case b of
      Left _ -> return ()
      _      -> mapM_ applyTx txs
    utxo <- use txUtxo
    txUtxoHistory %= (utxo:)

-- | Rollback last @n@ blocks. This will replace current utxo to utxo
-- of desired depth block and also filter local transactions so they
-- can be applied. @tx@ prefix is used, because rollback may happen in
-- other storages as well.
txRollback :: [WithHash Tx] -> Word -> Update ()
txRollback _ 0 = pass
txRollback localTxs (fromIntegral -> n) = do
    txUtxo <~ fromMaybe onError . (`atMay` n) <$> use txUtxoHistory
    txUtxoHistory %= drop n
    overrideWithLocalTxs localTxs
  where
    -- TODO Consider using `MonadError` and throwing `InternalError`.
    onError = (panic "attempt to rollback to too old or non-existing block")

processTx :: WithHash Tx -> Update ()
processTx = applyTx

-- | Erases local utxo and puts utxo of the last block on it's place.
resetLocalUtxo :: Update ()
resetLocalUtxo = do
    headUtxo <- uses txUtxoHistory head
    whenJust headUtxo $ \h -> txUtxo .= h

-- | Normalize local transaction list -- throw away all transactions
-- that don't make sense anymore (e.g. after block application that
-- spends utxo we were counting on). Returns new transaction list,
-- sorted.
filterLocalTxs :: [WithHash Tx] -> Update [WithHash Tx]
filterLocalTxs localTxs = do --TODO cosmetic fix it
    utxo <- use txUtxo
    pure $ normalizeTxs localTxs utxo

-- | Takes the utxo we have now, reset it to head of utxo history and
-- apply all localtransactions we have. It applies @filterLocalTxs@
-- inside, because we can't apply transactions that don't apply.
-- Returns filtered localTransactions
overrideWithLocalTxs :: [WithHash Tx] -> Update ()
overrideWithLocalTxs localTxs = do
    resetLocalUtxo
    txs <- filterLocalTxs localTxs
    forM_ txs applyTx
