module GeniusYield.Test.DEX.Option
  ( optionTests
  )
where

import Control.Monad.Reader (runReaderT)
import Data.Map.Strict qualified as Map
import Data.Ratio ((%))
import GeniusYield.HTTP.Errors (someBackendError)
import GeniusYield.Imports
import GeniusYield.Test.Clb (mkTestFor, mustFail, sendSkeleton)
import GeniusYield.Test.FakeCoin (fakeCoin)
import GeniusYield.Test.Utils
import GeniusYield.TxBuilder
import GeniusYield.Types
import Test.Tasty (TestTree, testGroup)

import GeniusYield.Api.DEX.Option
  ( OptionInfo (..)
  , cancelEarlyOption
  , createOption
  , executeOption
  , optionInfos
  , retrieveOption
  )
import GeniusYield.Scripts (GYCompiledScripts)

-------------------------------------------------------------------------------
-- Entry point
-------------------------------------------------------------------------------

optionTests :: GYCompiledScripts -> TestTree
optionTests gycs =
  testGroup
    "Option"
    [ mkTestFor "create option succeeds"
        $ optionCreateTrace gycs . testWallets
    , mkTestFor "execute option happy path"
        $ optionExecuteHappyTrace gycs . testWallets
    , mkTestFor "execute before start fails"
        $ mustFail . optionExecuteBeforeStartTrace gycs . testWallets
    , mkTestFor "execute after end fails"
        $ mustFail . optionExecuteAfterEndTrace gycs . testWallets
    , mkTestFor "cancelEarly before cutoff succeeds"
        $ optionCancelEarlyTrace gycs . testWallets
    , mkTestFor "cancelEarly after cutoff fails"
        $ mustFail . optionCancelEarlyAfterCutoffTrace gycs . testWallets
    , mkTestFor "retrieve after expiry succeeds"
        $ optionRetrieveAfterExpiryTrace gycs . testWallets
    , mkTestFor "retrieve before expiry fails"
        $ mustFail . optionRetrieveBeforeExpiryTrace gycs . testWallets
    ]

-------------------------------------------------------------------------------
-- Token helpers
-- Use the standard fake gold/iron so test wallets are pre-funded.
-------------------------------------------------------------------------------

-- Deposit asset: Gold tokens locked by the seller.
depositAC :: GYAssetClass
depositAC = fakeCoin fakeGold

-- Payment asset: Iron tokens paid by the executor.
paymentAC :: GYAssetClass
paymentAC = fakeCoin fakeIron

-- Price: 2 iron per gold.
optionPrice :: GYRational
optionPrice = rationalFromGHC (2 % 1)

-- Total deposit size (also total option tokens minted).
optionAmount :: Natural
optionAmount = 10

-------------------------------------------------------------------------------
-- Helper: find the option UTxO ref created by a given transaction.
-------------------------------------------------------------------------------

findOptionRef
  :: GYTxGameMonad m
  => GYCompiledScripts
  -> GYTxId
  -> m GYTxOutRef
findOptionRef gycs tid = do
  infos <- runReaderT optionInfos gycs
  case find (\oi -> fst (txOutRefToTuple (opiRef oi)) == tid) (Map.elems infos) of
    Just oi -> return (opiRef oi)
    Nothing  ->
      throwAppError $ someBackendError
        $ fromString
        $ printf "created option not found for txId %s" tid

-------------------------------------------------------------------------------
-- Test traces
-------------------------------------------------------------------------------

-- | Creating an option does not fail.
optionCreateTrace
  :: GYTxGameMonad m
  => GYCompiledScripts
  -> Wallets
  -> m ()
optionCreateTrace gycs Wallets {..} = asUser w1 $ do
  addr  <- ownChangeAddress
  pkh   <- addressToPubKeyHash' addr
  sc    <- slotConfig
  cSlot <- slotOfCurrentBlock
  let
    start  = slotToBeginTimePure sc cSlot
    end    = slotToBeginTimePure sc $ unsafeAdvanceSlot cSlot 100
    cutoff = slotToBeginTimePure sc $ unsafeAdvanceSlot cSlot 50
  sk <- runReaderT
    (createOption start end cutoff depositAC paymentAC optionPrice optionAmount pkh)
    gycs
  void $ sendSkeleton sk

-- | Create then execute a partial amount within the valid window.
optionExecuteHappyTrace
  :: GYTxGameMonad m
  => GYCompiledScripts
  -> Wallets
  -> m ()
optionExecuteHappyTrace gycs Wallets {..} = asUser w1 $ do
  addr  <- ownChangeAddress
  pkh   <- addressToPubKeyHash' addr
  sc    <- slotConfig
  cSlot <- slotOfCurrentBlock
  let
    start  = slotToBeginTimePure sc cSlot
    end    = slotToBeginTimePure sc $ unsafeAdvanceSlot cSlot 100
    cutoff = slotToBeginTimePure sc $ unsafeAdvanceSlot cSlot 50
  skCreate <- runReaderT
    (createOption start end cutoff depositAC paymentAC optionPrice optionAmount pkh)
    gycs
  tid <- sendSkeleton skCreate
  ref <- findOptionRef gycs tid
  -- Execute half the tokens: burn 5 option tokens, pay 10 iron.
  skExec <- runReaderT (executeOption ref 5) gycs
  void $ sendSkeleton skExec

-- | Execute before the start time — must fail.
optionExecuteBeforeStartTrace
  :: GYTxGameMonad m
  => GYCompiledScripts
  -> Wallets
  -> m ()
optionExecuteBeforeStartTrace gycs Wallets {..} = asUser w1 $ do
  addr  <- ownChangeAddress
  pkh   <- addressToPubKeyHash' addr
  sc    <- slotConfig
  cSlot <- slotOfCurrentBlock
  let
    -- Start is 20 slots ahead; we are at cSlot now.
    start  = slotToBeginTimePure sc $ unsafeAdvanceSlot cSlot 20
    end    = slotToBeginTimePure sc $ unsafeAdvanceSlot cSlot 100
    cutoff = slotToBeginTimePure sc $ unsafeAdvanceSlot cSlot 50
  skCreate <- runReaderT
    (createOption start end cutoff depositAC paymentAC optionPrice optionAmount pkh)
    gycs
  tid <- sendSkeleton skCreate
  ref <- findOptionRef gycs tid
  -- Stay at cSlot — before start.
  skExec <- runReaderT (executeOption ref 1) gycs
  void $ sendSkeleton skExec

-- | Execute after the end time — must fail.
optionExecuteAfterEndTrace
  :: GYTxGameMonad m
  => GYCompiledScripts
  -> Wallets
  -> m ()
optionExecuteAfterEndTrace gycs Wallets {..} = asUser w1 $ do
  addr  <- ownChangeAddress
  pkh   <- addressToPubKeyHash' addr
  sc    <- slotConfig
  cSlot <- slotOfCurrentBlock
  let
    start  = slotToBeginTimePure sc cSlot
    end    = slotToBeginTimePure sc $ unsafeAdvanceSlot cSlot 10
    cutoff = slotToBeginTimePure sc $ unsafeAdvanceSlot cSlot 5
  skCreate <- runReaderT
    (createOption start end cutoff depositAC paymentAC optionPrice optionAmount pkh)
    gycs
  tid <- sendSkeleton skCreate
  ref <- findOptionRef gycs tid
  -- Advance 20 slots past the 10-slot end.
  void $ waitUntilSlot $ unsafeAdvanceSlot cSlot 20
  skExec <- runReaderT (executeOption ref 1) gycs
  void $ sendSkeleton skExec

-- | Cancel early before the cutoff — must succeed.
optionCancelEarlyTrace
  :: GYTxGameMonad m
  => GYCompiledScripts
  -> Wallets
  -> m ()
optionCancelEarlyTrace gycs Wallets {..} = asUser w1 $ do
  addr  <- ownChangeAddress
  pkh   <- addressToPubKeyHash' addr
  sc    <- slotConfig
  cSlot <- slotOfCurrentBlock
  let
    start  = slotToBeginTimePure sc cSlot
    end    = slotToBeginTimePure sc $ unsafeAdvanceSlot cSlot 100
    cutoff = slotToBeginTimePure sc $ unsafeAdvanceSlot cSlot 50
  skCreate <- runReaderT
    (createOption start end cutoff depositAC paymentAC optionPrice optionAmount pkh)
    gycs
  tid <- sendSkeleton skCreate
  ref <- findOptionRef gycs tid
  -- We are at cSlot+1 or so — well before the 50-slot cutoff.
  skCancel <- runReaderT (cancelEarlyOption ref) gycs
  void $ sendSkeleton skCancel

-- | Cancel early after the cutoff — must fail.
optionCancelEarlyAfterCutoffTrace
  :: GYTxGameMonad m
  => GYCompiledScripts
  -> Wallets
  -> m ()
optionCancelEarlyAfterCutoffTrace gycs Wallets {..} = asUser w1 $ do
  addr  <- ownChangeAddress
  pkh   <- addressToPubKeyHash' addr
  sc    <- slotConfig
  cSlot <- slotOfCurrentBlock
  let
    start  = slotToBeginTimePure sc cSlot
    end    = slotToBeginTimePure sc $ unsafeAdvanceSlot cSlot 100
    cutoff = slotToBeginTimePure sc $ unsafeAdvanceSlot cSlot 5
  skCreate <- runReaderT
    (createOption start end cutoff depositAC paymentAC optionPrice optionAmount pkh)
    gycs
  tid <- sendSkeleton skCreate
  ref <- findOptionRef gycs tid
  -- Advance past the 5-slot cutoff.
  void $ waitUntilSlot $ unsafeAdvanceSlot cSlot 10
  skCancel <- runReaderT (cancelEarlyOption ref) gycs
  void $ sendSkeleton skCancel

-- | Retrieve deposits after the option interval has fully expired — must succeed.
optionRetrieveAfterExpiryTrace
  :: GYTxGameMonad m
  => GYCompiledScripts
  -> Wallets
  -> m ()
optionRetrieveAfterExpiryTrace gycs Wallets {..} = asUser w1 $ do
  addr  <- ownChangeAddress
  pkh   <- addressToPubKeyHash' addr
  sc    <- slotConfig
  cSlot <- slotOfCurrentBlock
  let
    start  = slotToBeginTimePure sc cSlot
    end    = slotToBeginTimePure sc $ unsafeAdvanceSlot cSlot 10
    cutoff = slotToBeginTimePure sc $ unsafeAdvanceSlot cSlot 5
  skCreate <- runReaderT
    (createOption start end cutoff depositAC paymentAC optionPrice optionAmount pkh)
    gycs
  tid <- sendSkeleton skCreate
  ref <- findOptionRef gycs tid
  -- Advance past end.
  void $ waitUntilSlot $ unsafeAdvanceSlot cSlot 15
  skRetrieve <- runReaderT (retrieveOption ref) gycs
  void $ sendSkeleton skRetrieve

-- | Retrieve before the option interval has expired — must fail.
optionRetrieveBeforeExpiryTrace
  :: GYTxGameMonad m
  => GYCompiledScripts
  -> Wallets
  -> m ()
optionRetrieveBeforeExpiryTrace gycs Wallets {..} = asUser w1 $ do
  addr  <- ownChangeAddress
  pkh   <- addressToPubKeyHash' addr
  sc    <- slotConfig
  cSlot <- slotOfCurrentBlock
  let
    start  = slotToBeginTimePure sc cSlot
    end    = slotToBeginTimePure sc $ unsafeAdvanceSlot cSlot 100
    cutoff = slotToBeginTimePure sc $ unsafeAdvanceSlot cSlot 50
  skCreate <- runReaderT
    (createOption start end cutoff depositAC paymentAC optionPrice optionAmount pkh)
    gycs
  tid <- sendSkeleton skCreate
  ref <- findOptionRef gycs tid
  -- End is 100 slots away — do not advance.
  skRetrieve <- runReaderT (retrieveOption ref) gycs
  void $ sendSkeleton skRetrieve
