/// Option validators — spend + mint.
///
/// Two separate validator blocks because they carry different compile-time parameters:
///
///   option_spend(nft_policy_id, fee_config_nft)  — governs Execute / Retrieve / CancelEarly
///   option_mint(nft_policy_id, spend_script_hash) — governs token minting / burning
///
/// Both share the `expected_token_name` derivation:
///   sha2_256( output_index_byte || transaction_id_bytes )
/// This matches the PlutusTx implementation exactly.

use aiken/collection/list
use aiken/crypto
use aiken/primitive/bytearray
use cardano/address.{Script}
use cardano/assets
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction,
}
use geniusyield/options/types.{
  AssetClass, CancelEarly, Execute, OptionDatum, OptionFeeConfigDatum,
  OptionRedeemer, Rational, Retrieve,
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Minimum ADA every option UTxO must carry (3 ADA, matching the PlutusTx constant).
const option_min_ada: Int = 3_000_000

/// Sentinel: fee config is disabled when fee_config_nft == ADA (empty policy + empty name).
const ada_policy_id: ByteArray = #""

const ada_asset_name: ByteArray = #""

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Derive the expected option / NFT token name from a UTxO reference.
///
/// Matches the PlutusTx formula:  sha2_256 (consByteString ix tid)
/// where `consByteString ix bs` prepends a single byte (ix mod 256) to bs.
fn expected_token_name(oref: OutputReference) -> ByteArray {
  crypto.sha2_256(bytearray.push(oref.transaction_id, oref.output_index))
}

/// Return the quantity of an asset class held in a `Value`.
fn qty(value: assets.Value, ac: AssetClass) -> Int {
  assets.quantity_of(value, ac.policy_id, ac.asset_name)
}

/// True iff the validity range lower bound is a finite value >= `t`.
fn valid_from_at_least(tx: Transaction, t: Int) -> Bool {
  when tx.validity_range.lower_bound.bound_type is {
    Finite(lb) -> lb >= t
    _ -> False
  }
}

/// True iff the validity range upper bound is a finite value <= `t`.
fn valid_until_at_most(tx: Transaction, t: Int) -> Bool {
  when tx.validity_range.upper_bound.bound_type is {
    Finite(ub) -> ub <= t
    _ -> False
  }
}

/// Find the single output at `addr`; fail if there is not exactly one.
fn find_deposit(tx: Transaction, own_address: cardano/address.Address) -> Output {
  when list.filter(tx.outputs, fn(o) { o.address == own_address }) is {
    [o] -> o
    _ -> fail @"expected exactly one deposit output"
  }
}

/// Look up the fee-config datum from a reference input carrying `fee_nft`.
fn find_fee_config(
  ref_inputs: List<Input>,
  fee_nft: AssetClass,
) -> Option<OptionFeeConfigDatum> {
  when ref_inputs is {
    [] -> None
    [inp, ..rest] ->
      if assets.quantity_of(
        inp.output.value,
        fee_nft.policy_id,
        fee_nft.asset_name,
      ) == 1 {
        expect InlineDatum(raw) = inp.output.datum
        expect cfg: OptionFeeConfigDatum = raw
        Some(cfg)
      } else {
        find_fee_config(rest, fee_nft)
      }
  }
}

/// Verify that `req` of the listed `authorised` keys have signed the transaction.
fn has_required_sigs(
  tx_sigs: List<ByteArray>,
  authorised: List<ByteArray>,
  req: Int,
) -> Bool {
  let count =
    list.foldr(
      authorised,
      0,
      fn(pkh, acc) {
        if list.has(tx_sigs, pkh) {
          acc + 1
        } else {
          acc
        }
      },
    )
  count >= req
}

// ---------------------------------------------------------------------------
// Spend validator
// ---------------------------------------------------------------------------

/// Governs execution, retrieval and early cancellation of options.
///
/// Parameters:
///   nft_policy_id  — currency symbol of the NFT minting policy (used to derive the NFT asset class)
///   fee_config_nft — asset class of the fee-config UTxO.
///                    Pass the ADA sentinel (empty policy + empty name) to disable fees.
validator option_spend(nft_policy_id: ByteArray, fee_config_nft: AssetClass) {
  spend(
    datum_opt: Option<OptionDatum>,
    redeemer: OptionRedeemer,
    oref: OutputReference,
    tx: Transaction,
  ) {
    expect Some(d) = datum_opt

    let OptionDatum {
      ref: opd_ref,
      token: opd_token,
      start: opd_start,
      end: opd_end,
      cancel_cutoff: opd_cancel_cutoff,
      deposit: opd_deposit,
      payment: opd_payment,
      price: opd_price,
      seller_key: opd_seller_key,
    } = d

    let nft_ac =
      AssetClass {
        policy_id: nft_policy_id,
        asset_name: expected_token_name(opd_ref),
      }

    // Find our own input to determine own address and value.
    expect Some(own_input) =
      list.find(tx.inputs, fn(i) { i.output_reference == oref })
    let own_address = own_input.output.address
    let own_value = own_input.output.value

    when redeemer is {
      // -----------------------------------------------------------------
      // Execute
      // -----------------------------------------------------------------
      Execute { amount } -> {
        let deposit_output = find_deposit(tx, own_address)
        let deposit_value = deposit_output.value

        // Validity window must be entirely within [start, end].
        let time_valid =
          valid_from_at_least(tx, opd_start) && valid_until_at_most(
            tx,
            opd_end,
          )

        // Exactly `amount` option tokens must be burnt.
        let tokens_burnt =
          assets.quantity_of(tx.mint, opd_token.policy_id, opd_token.asset_name) == -amount

        // NFT must remain in the continuing deposit output.
        let nft_in_deposit = qty(deposit_value, nft_ac) == 1

        // Datum must be unchanged.
        let same_datum =
          when deposit_output.datum is {
            InlineDatum(raw) -> {
              expect od: OptionDatum = raw
              od == d
            }
            _ -> False
          }

        // Deposit taken must not exceed `amount`.
        let deposit_before = qty(own_value, opd_deposit)
        let deposit_after = qty(deposit_value, opd_deposit)
        let deposit_taken = deposit_before - deposit_after

        // ADA taken is only allowed when one side is ADA.
        let ada_before = assets.lovelace_of(own_value)
        let ada_after = assets.lovelace_of(deposit_value)
        let ada_taken = ada_before - ada_after

        let is_ada_deposit =
          opd_deposit.policy_id == ada_policy_id && opd_deposit.asset_name == ada_asset_name
        let is_ada_payment =
          opd_payment.policy_id == ada_policy_id && opd_payment.asset_name == ada_asset_name

        let not_taken_too_much =
          deposit_taken <= amount && ( ada_taken <= 0 || is_ada_deposit || is_ada_payment )

        // Payment must be >= price * amount (avoid floating-point: cross-multiply).
        let payment_before = qty(own_value, opd_payment)
        let payment_after = qty(deposit_value, opd_payment)
        let actual_payment = payment_after - payment_before

        // actual_payment >= price.numerator * amount / price.denominator
        // ↔ actual_payment * denominator >= numerator * amount
        let payment_sufficient =
          actual_payment * opd_price.denominator >= opd_price.numerator * amount

        // Protocol fee check (skipped when fee config NFT is the ADA sentinel).
        let fee_ok =
          if
          fee_config_nft.policy_id == ada_policy_id && fee_config_nft.asset_name == ada_asset_name{
            True
          } else {
            when find_fee_config(tx.reference_inputs, fee_config_nft) is {
              None -> fail @"fee config not in reference inputs"
              Some(cfg) ->
                if cfg.numerator <= 0 {
                  True
                } else {
                  let fee_due =
                    actual_payment * cfg.numerator / cfg.denominator
                  let fee_paid =
                    list.foldr(
                      tx.outputs,
                      0,
                      fn(o, acc) {
                        if o.address == cfg.fee_address {
                          acc + qty(o.value, opd_payment)
                        } else {
                          acc
                        }
                      },
                    )
                  fee_paid >= fee_due
                }
            }
          }

        and {
          time_valid?,
          tokens_burnt?,
          nft_in_deposit?,
          same_datum?,
          not_taken_too_much?,
          payment_sufficient?,
          fee_ok?,
        }
      }

      // -----------------------------------------------------------------
      // Retrieve
      // -----------------------------------------------------------------
      Retrieve -> {
        let nft_burnt =
          assets.quantity_of(tx.mint, nft_ac.policy_id, nft_ac.asset_name) == -1

        let signed_by_seller = list.has(tx.extra_signatories, opd_seller_key)

        // Validity range must start at or after `end`.
        let deadline_passed = valid_from_at_least(tx, opd_end)

        // At least one output must go to a pubkey address matching the seller.
        let funds_to_seller =
          list.any(
            tx.outputs,
            fn(o) {
              when o.address.payment_credential is {
                cardano/address.VerificationKey(pkh) -> pkh == opd_seller_key
                _ -> False
              }
            },
          )

        and {
          nft_burnt?,
          signed_by_seller?,
          deadline_passed?,
          funds_to_seller?,
        }
      }

      // -----------------------------------------------------------------
      // CancelEarly
      // -----------------------------------------------------------------
      CancelEarly -> {
        let signed_by_seller = list.has(tx.extra_signatories, opd_seller_key)

        // Validity range upper bound must be strictly before cancel_cutoff.
        let before_cutoff = valid_until_at_most(tx, opd_cancel_cutoff - 1)

        // All remaining option tokens must be burnt.
        let remaining_deposit =
          if is_ada(opd_deposit) {
            assets.lovelace_of(own_value) - option_min_ada
          } else {
            qty(own_value, opd_deposit)
          }
        let unsold_tokens_burnt =
          assets.quantity_of(tx.mint, opd_token.policy_id, opd_token.asset_name) == -remaining_deposit

        let nft_burnt =
          assets.quantity_of(tx.mint, nft_ac.policy_id, nft_ac.asset_name) == -1

        and {
          signed_by_seller?,
          before_cutoff?,
          unsold_tokens_burnt?,
          nft_burnt?,
        }
      }
    }
  }

  else(_) {
    fail
  }
}

/// True iff the asset class is ADA (empty policy + empty name).
fn is_ada(ac: AssetClass) -> Bool {
  ac.policy_id == ada_policy_id && ac.asset_name == ada_asset_name
}

// ---------------------------------------------------------------------------
// Mint / burn policy
// ---------------------------------------------------------------------------

/// Governs minting of option tokens (and the associated NFT is minted simultaneously
/// by the NFT policy — this policy only checks option token minting rules).
///
/// Parameters:
///   nft_policy_id   — currency symbol of the NFT policy (used to verify NFT is present)
///   spend_hash      — script hash of the option_spend validator (used to derive the
///                     option validator address for deposit output checks)
validator option_mint(nft_policy_id: ByteArray, spend_hash: ByteArray) {
  mint(redeemer: OutputReference, policy_id: ByteArray, tx: Transaction) {
    // Derive own token name from the redeemer UTxO reference.
    let option_name = expected_token_name(redeemer)

    // Count how many option tokens are being minted (positive only).
    let minted_amount =
      assets.quantity_of(tx.mint, policy_id, option_name)

    // Burning is always allowed.
    if minted_amount <= 0 {
      True
    } else {
      // Derive the expected validator address (Script credential, no staking).
      let validator_address =
        cardano/address.Address {
          payment_credential: Script(spend_hash),
          stake_credential: None,
        }

      let nft_ac =
        AssetClass {
          policy_id: nft_policy_id,
          asset_name: expected_token_name(redeemer),
        }

      let own_token_ac =
        AssetClass { policy_id: policy_id, asset_name: option_name }

      // The UTxO referenced by the redeemer must be consumed.
      let input_consumed =
        list.any(tx.inputs, fn(i) { i.output_reference == redeemer })

      // Find the single deposit output at the validator address.
      let deposit_output = find_deposit(tx, validator_address)
      let deposit_value = deposit_output.value

      // Deposit datum must reference the same UTxO and carry the correct token ac.
      let check_deposit_datum =
        when deposit_output.datum is {
          InlineDatum(raw) -> {
            expect od: OptionDatum = raw
            od.ref == redeemer && od.token == own_token_ac
          }
          _ -> False
        }

      // Deposit value must contain the NFT and enough deposit tokens (minus min-ADA).
      let without_min_ada =
        assets.merge(
          deposit_value,
          assets.from_lovelace(-option_min_ada),
        )

      let has_nft = qty(without_min_ada, nft_ac) == 1

      let deposit_sufficient = {
        expect InlineDatum(raw) = deposit_output.datum
        expect od: OptionDatum = raw
        qty(without_min_ada, od.deposit) >= minted_amount
      }

      let check_token_name =
        assets.quantity_of(tx.mint, policy_id, option_name) > 0

      and {
        input_consumed?,
        check_deposit_datum?,
        has_nft?,
        deposit_sufficient?,
        check_token_name?,
      }
    }
  }

  else(_) {
    fail
  }
}
