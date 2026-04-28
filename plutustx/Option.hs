{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE NoImplicitPrelude #-}

{- |
Module      : GeniusYield.OnChain.DEX.Option
Copyright   : (c) 2023 GYELD GMBH
License     : Apache 2.0
Maintainer  : support@geniusyield.com
Stability   : develop
-}
module GeniusYield.OnChain.DEX.Option
  ( OptionDatum (..)
  , OptionRedeemer (..)
  , optionMinAda
  , noFeeConfigNft
  , mkOptionValidator
  , mkOptionPolicy
  )
where

import PlutusLedgerApi.V1.Interval (contains, from, interval, to)
import PlutusLedgerApi.V1.Value
import PlutusLedgerApi.V2
import PlutusLedgerApi.V2.Contexts (txSignedBy)
import PlutusTx qualified
import PlutusTx.Prelude

import GeniusYield.OnChain.DEX.OptionFeeConfig (OptionFeeConfigDatum (..))
import GeniusYield.OnChain.Utils (check')

data OptionDatum = OptionDatum
  { opdRef :: TxOutRef
  -- ^ Reference to the UTxO used to mint both the NFT and the option tokens.
  , opdToken :: AssetClass
  -- ^ Asset class of the option tokens.
  , opdStart :: POSIXTime
  -- ^ Start of the interval during which the option can be executed.
  , opdEnd :: POSIXTime
  -- ^ End of the interval during which the option can be executed.
  , opdCancelCutoff :: POSIXTime
  -- ^ Deadline before which the writer may cancel early via CancelEarly.
  -- Must satisfy: opdStart <= opdCancelCutoff <= opdEnd.
  , opdDeposit :: AssetClass
  -- ^ Asset class of the deposited tokens.
  , opdPayment :: AssetClass
  -- ^ Asset class of the payment tokens.
  , opdPrice :: Rational
  -- ^ Execution price of one deposited token guaranteed by the option.
  , opdSellerKey :: PubKeyHash
  -- ^ Public key hash of the seller of the option.
  }

PlutusTx.makeIsDataIndexed ''OptionDatum [('OptionDatum, 0)]

instance Eq OptionDatum where
  x == y =
    (opdRef x == opdRef y)
      && (opdToken x == opdToken y)
      && (opdStart x == opdStart y)
      && (opdEnd x == opdEnd y)
      && (opdCancelCutoff x == opdCancelCutoff y)
      && (opdDeposit x == opdDeposit y)
      && (opdPayment x == opdPayment y)
      && (opdPrice x == opdPrice y)
      && (opdSellerKey x == opdSellerKey y)

data OptionRedeemer
  = -- | Execute the given number of option tokens during the execution interval.
    Execute Integer
  | -- | Retrieve payment tokens and remaining deposit tokens after the execution interval has passed.
    Retrieve
  | -- | Writer cancels early before opdCancelCutoff, burning all unsold option tokens.
    CancelEarly

PlutusTx.makeIsDataIndexed ''OptionRedeemer [('Execute, 0), ('Retrieve, 1), ('CancelEarly, 2)]

-- | The asset class for the ada token.
{-# INLINEABLE adaAC #-}
adaAC :: AssetClass
adaAC = assetClass adaSymbol adaToken

-- | Value used to satisfy the minimum ada requirement of an UTxO.
{-# INLINEABLE optionMinAda #-}
optionMinAda :: Value
optionMinAda = assetClassValue adaAC 3_000_000

-- | Sentinel asset class meaning "no fee config": fees are disabled.
-- Use this as the feeConfigNft parameter when deploying without protocol fees.
{-# INLINEABLE noFeeConfigNft #-}
noFeeConfigNft :: AssetClass
noFeeConfigNft = adaAC

{-# INLINEABLE mkOptionValidator #-}
mkOptionValidator
  :: CurrencySymbol
  -- ^ Currency symbol of the NFT.
  -> AssetClass
  -- ^ Asset class of the fee-config NFT. Pass 'noFeeConfigNft' (= ADA) to disable fees.
  -> BuiltinData
  -- ^ Datum (of type `OptionDatum`).
  -> BuiltinData
  -- ^ Redeemer (of type `OptionRedeemer`).
  -> BuiltinData
  -- ^ Script context.
  -> ()
mkOptionValidator nftSymbol feeConfigNft d r c =
  check'
    $ mkOptionValidator' nftSymbol feeConfigNft (unsafeFromBuiltinData d) (unsafeFromBuiltinData r) (unsafeFromBuiltinData c)

{-# INLINEABLE mkOptionPolicy #-}
mkOptionPolicy
  :: CurrencySymbol
  -- ^ Currency symbol of the NFT.
  -> Address
  -- ^ Address of the option validator script.
  -> BuiltinData
  -- ^ Redeemer, given by the `TxOutRef` of the UTxO that must be spent to mint the NFT.
  -> BuiltinData
  -- ^ Script context.
  -> ()
mkOptionPolicy nftSymbol addr r c =
  check'
    $ mkOptionPolicy' nftSymbol addr (unsafeFromBuiltinData r) (unsafeFromBuiltinData c)

{-# INLINEABLE mkOptionValidator' #-}
mkOptionValidator'
  :: CurrencySymbol
  -> AssetClass
  -> OptionDatum
  -> OptionRedeemer
  -> ScriptContext
  -> Bool
mkOptionValidator' nftSymbol feeConfigNft d@OptionDatum {..} r ScriptContext {..} = case r of
  Execute amount ->
    traceIfFalse "time invalid" timeValid
      && traceIfFalse "tokens not burnt" (tokensBurnt amount)
      && traceIfFalse "NFT missing from continuing output" nftInDeposit
      && traceIfFalse "continuing output has wrong datum" sameDatum
      && traceIfFalse "taken too much" (notTakenTooMuch amount)
      && traceIfFalse "paid too little" (paymentSufficient amount)
      && traceIfFalse "protocol fee not paid" (protocolFeePaid amount)
  Retrieve ->
    traceIfFalse "NFT not burnt" nftBurnt
      && traceIfFalse "not signed by seller" signedBySeller
      && traceIfFalse "deadline not passed" deadlinePassed
      && traceIfFalse "funds not sent to seller" fundsToSeller
  CancelEarly ->
    traceIfFalse "not signed by seller" signedBySeller
      && traceIfFalse "cancel cutoff passed" beforeCutoff
      && traceIfFalse "unsold tokens not all burnt" unsoldTokensBurnt
      && traceIfFalse "NFT not burnt" nftBurnt
  where
    info :: TxInfo
    info = scriptContextTxInfo

    validRange :: POSIXTimeRange
    validRange = txInfoValidRange info

    mint :: Value
    mint = txInfoMint info

    nft :: AssetClass
    nft = assetClass nftSymbol $ expectedTokenName opdRef

    timeValid :: Bool
    timeValid = interval opdStart opdEnd `contains` validRange

    tokensBurnt :: Integer -> Bool
    tokensBurnt amount = assetClassValueOf mint opdToken == negate amount

    ownInput :: TxOut
    ownInput = case scriptContextPurpose of
      Spending ref -> case xs of
        [i] -> txInInfoResolved i
        _xs -> traceError "impossible branch"
        where
          xs :: [TxInInfo]
          xs =
            [ i
            | i <- txInfoInputs info
            , txInInfoOutRef i == ref
            ]
      _p -> traceError "expected purpose 'Spending'"

    ownAddress :: Address
    ownAddress = txOutAddress ownInput

    ownValue :: Value
    ownValue = txOutValue ownInput

    depositDatum :: OptionDatum
    depositValue :: Value
    (depositDatum, depositValue) = findDeposit info ownAddress

    nftInDeposit :: Bool
    nftInDeposit = assetClassValueOf depositValue nft == 1

    sameDatum :: Bool
    sameDatum = depositDatum == d

    notTakenTooMuch :: Integer -> Bool
    notTakenTooMuch amount =
      (depositTaken <= amount)
        && (adaTaken <= 0 || opdDeposit == adaAC || opdPayment == adaAC)
      where
        depositTaken, adaTaken :: Integer
        depositTaken = assetClassValueOf ownValue opdDeposit - assetClassValueOf depositValue opdDeposit
        adaTaken = assetClassValueOf ownValue adaAC - assetClassValueOf depositValue adaAC

    paymentSufficient :: Integer -> Bool
    paymentSufficient amount = fromInteger actualPayment >= expectedPayment
      where
        actualPayment :: Integer
        actualPayment = assetClassValueOf depositValue opdPayment - assetClassValueOf ownValue opdPayment

        expectedPayment :: Rational
        expectedPayment = opdPrice * fromInteger amount

    nftBurnt :: Bool
    nftBurnt = assetClassValueOf mint nft == (-1)

    signedBySeller :: Bool
    signedBySeller = txSignedBy info opdSellerKey

    deadlinePassed :: Bool
    deadlinePassed = from opdEnd `contains` validRange

    -- Verify at least one output goes to the seller's pubkey address.
    fundsToSeller :: Bool
    fundsToSeller = any goesToSeller (txInfoOutputs info)
      where
        goesToSeller :: TxOut -> Bool
        goesToSeller out = case addressCredential (txOutAddress out) of
          PubKeyCredential pkh -> pkh == opdSellerKey
          _                    -> False

    -- Transaction validity range must be entirely before the cancel cutoff.
    beforeCutoff :: Bool
    beforeCutoff = to (opdCancelCutoff - 1) `contains` validRange

    -- Burn exactly the remaining deposit amount of option tokens.
    -- For non-ADA deposits, ownValue's deposit balance equals outstanding option tokens.
    unsoldTokensBurnt :: Bool
    unsoldTokensBurnt =
      assetClassValueOf mint opdToken == negate remainingDeposit
      where
        remainingDeposit :: Integer
        remainingDeposit
          | opdDeposit == adaAC = assetClassValueOf ownValue adaAC - 3_000_000
          | otherwise           = assetClassValueOf ownValue opdDeposit

    -- Protocol fee check on Execute.
    -- Disabled when feeConfigNft == noFeeConfigNft (the ADA sentinel).
    protocolFeePaid :: Integer -> Bool
    protocolFeePaid _amount
      | feeConfigNft == adaAC = True -- fee disabled for this deployment
    protocolFeePaid _amount = case mFeeConfig of
      Nothing  -> traceError "fee config not in reference inputs"
      Just cfg
        | ofcdNumerator cfg <= 0 -> True -- zero-fee config
        | otherwise ->
            let
              paymentIn  = assetClassValueOf depositValue opdPayment
                         - assetClassValueOf ownValue    opdPayment
              requiredFee = (paymentIn * ofcdNumerator cfg) `divide` ofcdDenominator cfg
              feeToAddr   = foldl
                              (\acc o -> acc + assetClassValueOf (txOutValue o) opdPayment)
                              0
                              [ o | o <- txInfoOutputs info
                              , txOutAddress o == ofcdFeeAddress cfg ]
            in feeToAddr >= requiredFee

    mFeeConfig :: Maybe OptionFeeConfigDatum
    mFeeConfig = findFeeConfig (txInfoReferenceInputs info)

    findFeeConfig :: [TxInInfo] -> Maybe OptionFeeConfigDatum
    findFeeConfig [] = Nothing
    findFeeConfig (TxInInfo {txInInfoResolved = out} : rest)
      | assetClassValueOf (txOutValue out) feeConfigNft /= 1 = findFeeConfig rest
      | otherwise = case txOutDatum out of
          OutputDatum (Datum d') -> case fromBuiltinData d' of
            Just cfg -> Just cfg
            Nothing  -> findFeeConfig rest -- wrong datum type, keep searching
          _          -> findFeeConfig rest -- no inline datum, keep searching

{-# INLINEABLE mkOptionPolicy' #-}
mkOptionPolicy' :: CurrencySymbol -> Address -> TxOutRef -> ScriptContext -> Bool
mkOptionPolicy' nftSymbol addr ref ScriptContext {..}
  | mintedAmount <= 0 = True -- burning options is always allowed (if not necessarily advisable)
  | otherwise =
      traceIfFalse "input not consumed" inputConsumed
        && traceIfFalse "wrong token name" checkTokenName
        && traceIfFalse "wrong deposit datum" checkDepositDatum
        && traceIfFalse "wrong deposit value" checkDepositValue
  where
    info :: TxInfo
    info = scriptContextTxInfo

    ownSymbol :: CurrencySymbol
    ownSymbol = case scriptContextPurpose of
      Minting cs -> cs
      _purpose -> traceError "expected purpose 'Minting'"

    nft, ownToken :: AssetClass
    nft = assetClass nftSymbol $ expectedTokenName ref
    ownToken = assetClass ownSymbol optionName

    optionName :: TokenName
    mintedAmount :: Integer
    (optionName, mintedAmount) = case xs of
      [tn_amt] -> tn_amt
      _minted -> traceError "more than one token name"
      where
        xs :: [(TokenName, Integer)]
        xs =
          [ (tn, amt)
          | (cs, tn, amt) <- flattenValue $ txInfoMint info
          , cs == ownSymbol
          ]

    inputConsumed :: Bool
    inputConsumed = any (\i -> txInInfoOutRef i == ref) $ txInfoInputs info

    depositDatum :: OptionDatum
    depositValue :: Value
    (depositDatum, depositValue) = findDeposit info addr

    checkDepositDatum :: Bool
    checkDepositDatum =
      opdRef depositDatum
        == ref
        && opdToken depositDatum
        == ownToken

    checkDepositValue :: Bool
    checkDepositValue = hasNFT && isSufficient
      where
        withoutMinAda :: Value
        withoutMinAda = depositValue `gsub` optionMinAda

        -- The NFT must be contained in the deposit output.
        hasNFT :: Bool
        hasNFT = assetClassValueOf withoutMinAda nft == 1

        -- Enough tokens must be deposited.
        isSufficient :: Bool
        isSufficient = assetClassValueOf withoutMinAda (opdDeposit depositDatum) >= mintedAmount

    checkTokenName :: Bool
    checkTokenName = optionName == expectedTokenName ref

{-# INLINEABLE expectedTokenName #-}
expectedTokenName :: TxOutRef -> TokenName
expectedTokenName (TxOutRef (TxId tid) ix) = TokenName s
  where
    s :: BuiltinByteString
    s = sha2_256 (consByteString ix tid)

{-# INLINEABLE findDeposit #-}
findDeposit :: TxInfo -> Address -> (OptionDatum, Value)
findDeposit info addr = case xs of
  [o] -> case txOutDatum o of
    OutputDatum (Datum d) -> case fromBuiltinData d of
      Just od -> (od, txOutValue o)
      Nothing -> traceError "inline deposit datum has wrong type"
    _d -> traceError "expected inline deposit datum"
  _xs -> traceError "expected exactly one deposit output"
  where
    xs :: [TxOut]
    xs =
      [ o
      | o <- txInfoOutputs info
      , txOutAddress o == addr
      ]
