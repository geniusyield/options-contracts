{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE NoImplicitPrelude #-}

{- |
Module      : GeniusYield.OnChain.DEX.OptionFeeConfig
Copyright   : (c) 2023 GYELD GMBH
License     : Apache 2.0
Maintainer  : support@geniusyield.com
Stability   : develop
-}
module GeniusYield.OnChain.DEX.OptionFeeConfig
  ( OptionFeeConfigDatum (..)
  , mkOptionFeeConfigValidator
  )
where

import PlutusLedgerApi.V1.Value (AssetClass, assetClassValueOf)
import PlutusLedgerApi.V2
import PlutusTx qualified
import PlutusTx.Prelude

import GeniusYield.OnChain.Utils (check')

-- | Protocol-level fee configuration for option execution.
data OptionFeeConfigDatum = OptionFeeConfigDatum
  { ofcdSignatories    :: [PubKeyHash]
  -- ^ Public key hashes authorised to update this config.
  , ofcdReqSignatories :: Integer
  -- ^ Number of signatures required for an update.
  , ofcdFeeAddress     :: Address
  -- ^ Address that receives protocol fees on option execution.
  , ofcdNumerator      :: Integer
  -- ^ Fee numerator: fee = payment * N / D. 0 means no fee.
  , ofcdDenominator    :: Integer
  -- ^ Fee denominator (must be > 0).
  }

PlutusTx.makeIsDataIndexed ''OptionFeeConfigDatum [('OptionFeeConfigDatum, 0)]

{-# INLINEABLE mkOptionFeeConfigValidator #-}
mkOptionFeeConfigValidator
  :: AssetClass
  -- ^ Asset class of the reference NFT that identifies this config UTxO.
  -> BuiltinData
  -> BuiltinData
  -> BuiltinData
  -> ()
mkOptionFeeConfigValidator configNft d _r c =
  check'
    $ mkOptionFeeConfigValidator' configNft (unsafeFromBuiltinData d) (unsafeFromBuiltinData c)

{-# INLINEABLE mkOptionFeeConfigValidator' #-}
mkOptionFeeConfigValidator'
  :: AssetClass
  -> OptionFeeConfigDatum
  -> ScriptContext
  -> Bool
mkOptionFeeConfigValidator' configNft d ScriptContext {..} =
  traceIfFalse "config NFT missing from input"    ownInputHasNft
    && traceIfFalse "config NFT missing from output"  ownOutputHasNft
    && traceIfFalse "non-positive denominator"        positiveDenominator
    && traceIfFalse "negative numerator"              nonNegativeNumerator
    && traceIfFalse "non-positive req signatories"    positiveReqSignatories
    && traceIfFalse "too many required signatories"   reqSignatoriesNotTooBig
    && traceIfFalse "missing required signatures"     hasSignatures
  where
    OptionFeeConfigDatum sigs reqSigs _ _ _ = d

    info :: TxInfo
    info = scriptContextTxInfo

    hasNft :: TxOut -> Bool
    hasNft out = assetClassValueOf (txOutValue out) configNft == 1

    ownInput :: TxOut
    ownInput = go (txInfoInputs info)
      where
        ownRef = case scriptContextPurpose of
          Spending ref -> ref
          _            -> traceError "expected Spending purpose"
        go [] = traceError "own input not found"
        go (TxInInfo {..} : ins)
          | txInInfoOutRef == ownRef = txInInfoResolved
          | otherwise                = go ins

    ownOutput :: TxOut
    ownOutput = go (txInfoOutputs info)
      where
        ownAddr = txOutAddress ownInput
        go [] = traceError "no continuing output with config NFT"
        go (out : outs)
          | txOutAddress out == ownAddr && hasNft out = out
          | otherwise                                 = go outs

    newDatum :: OptionFeeConfigDatum
    newDatum = case txOutDatum ownOutput of
      OutputDatum x -> unsafeFromBuiltinData (getDatum x)
      _             -> traceError "expected inline datum on continuing output"

    ownInputHasNft :: Bool
    ownInputHasNft = hasNft ownInput

    ownOutputHasNft :: Bool
    ownOutputHasNft = hasNft ownOutput

    positiveDenominator :: Bool
    positiveDenominator = let OptionFeeConfigDatum _ _ _ _ denom = newDatum in denom > 0

    nonNegativeNumerator :: Bool
    nonNegativeNumerator = let OptionFeeConfigDatum _ _ _ num _ = newDatum in num >= 0

    positiveReqSignatories :: Bool
    positiveReqSignatories = let OptionFeeConfigDatum _ req _ _ _ = newDatum in req >= 1

    reqSignatoriesNotTooBig :: Bool
    reqSignatoriesNotTooBig =
      let OptionFeeConfigDatum newSigs newReq _ _ _ = newDatum
      in length newSigs >= newReq

    hasSignatures :: Bool
    hasSignatures = go 0 (txInfoSignatories info) sigs
      where
        go cnt _ _
          | cnt >= reqSigs = True
        go _ [] _ = False
        go cnt (pkh : pkhs) authorised = case pkh `elem'` authorised of
          Nothing          -> go cnt pkhs authorised
          Just authorised' -> go (cnt + 1) pkhs authorised'

{-# INLINEABLE elem' #-}
elem' :: Eq a => a -> [a] -> Maybe [a]
elem' _ [] = Nothing
elem' x (y : ys)
  | x == y    = Just ys
  | otherwise = case elem' x ys of
      Nothing  -> Nothing
      Just ys' -> Just (y : ys')
