/// On-chain types shared between the option spend validator and minting policy.

use cardano/address.{Address}
use cardano/assets.{AssetName, PolicyId}
use cardano/transaction.{OutputReference}

// ---------------------------------------------------------------------------
// Rational
// ---------------------------------------------------------------------------

/// Exact rational price.  Denominator must be > 0 (enforced off-chain at create time).
pub type Rational {
  numerator: Int,
  denominator: Int,
}

// ---------------------------------------------------------------------------
// Asset class
// ---------------------------------------------------------------------------

pub type AssetClass {
  policy_id: PolicyId,
  asset_name: AssetName,
}

// ---------------------------------------------------------------------------
// Option datum
// ---------------------------------------------------------------------------

/// Datum stored in the option validator UTxO.
pub type OptionDatum {
  /// The UTxO consumed to mint both the NFT and the option tokens.
  /// Used to derive the expected NFT and option token names.
  ref: OutputReference,
  /// Asset class of the minted option tokens.
  token: AssetClass,
  /// Earliest POSIX time (ms) at which the option may be exercised.
  start: Int,
  /// Latest POSIX time (ms) at which the option may be exercised.
  end: Int,
  /// Deadline before which the writer may cancel early.
  /// Invariant (checked off-chain): start <= cancel_cutoff <= end.
  cancel_cutoff: Int,
  /// Asset class deposited by the seller.
  deposit: AssetClass,
  /// Asset class expected from the executor as payment.
  payment: AssetClass,
  /// Price in payment-asset units per one deposit-asset unit.
  price: Rational,
  /// Seller's verification key hash for authorisation checks.
  seller_key: ByteArray,
}

// ---------------------------------------------------------------------------
// Option redeemer
// ---------------------------------------------------------------------------

pub type OptionRedeemer {
  /// Executor burns `amount` option tokens and receives `amount` deposit tokens.
  Execute { amount: Int }
  /// Seller reclaims all remaining assets after `end` has passed.
  Retrieve
  /// Seller cancels early before `cancel_cutoff`, burning all outstanding tokens.
  CancelEarly
}

// ---------------------------------------------------------------------------
// Fee config datum (read from a reference input)
// ---------------------------------------------------------------------------

/// Stored in the fee-config UTxO.  Referenced (not spent) during Execute.
pub type OptionFeeConfigDatum {
  /// PKHs authorised to update this config.
  signatories: List<ByteArray>,
  /// Minimum number of signatories required to update.
  req_signatories: Int,
  /// Address that receives protocol fees.
  fee_address: Address,
  /// Fee = payment * numerator / denominator.  Zero means no fee.
  numerator: Int,
  denominator: Int,
}
