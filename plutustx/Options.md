# Options

## Brief introduction to Options financial instrument

In traditional finance, the two main types of options are _call_ and _put_ options. In every option, there are two parties, the _option buyer_ and _option writer_, whose role is explained below.

A call option gives the buyer of the option the ability to buy a certain amount of an underlying asset at an _exercise price_, or _strike price_, by the expiration date of the contract[^1]. If the option is exercised, the option writer, or seller, must deliver the asset at the exercise price.

If the asset’s market price increases above the exercise price before expiration, the call option buyer could profit by first exercising the option to buy the asset at the strike price and then subsequently sell it on an exchange at the higher market price.

A put option gives the buyer of the option the ability to sell a certain amount of an underlying asset at a specific price by the expiration date of the contract. If the put option is exercised, the option writer must buy the asset at the strike price.

If the asset’s market price decreases below the exercise price, the put option buyer could profit by exercising the option to sell the asset at the strike price after buying it on an exchange at the lower market price.

In this way, we see that options differ from other derivatives, such as futures, in that option buyers have the right, but not obligation, to exercise the option before expiration. But this right is gained by paying a premium to option writer.

## [Options smart contract](./Option.hs)

If option writer wants to create an option, then they provide for fields given in `OptionDatum` (fields explained afterwards):

```haskell
data OptionDatum = OptionDatum
    { opdRef       :: TxOutRef   -- ^ Reference to the UTxO used to mint both the NFT and the option tokens.
    , opdToken     :: AssetClass -- ^ Asset class of the option tokens.
    , opdStart     :: POSIXTime  -- ^ Start of the interval during which the option can be executed.
    , opdEnd       :: POSIXTime  -- ^ End of the interval during which the option can be executed.
    , opdDeposit   :: AssetClass -- ^ Asset class of the deposited tokens.
    , opdPayment   :: AssetClass -- ^ Asset class of the payment tokens.
    , opdPrice     :: Rational   -- ^ Execution price of one deposited token guaranteed by the option.
    , opdSellerKey :: PubKeyHash -- ^ Public key hash of the seller of the option.
    }
```

Here `opdStart` & `opdEnd` determine that start & end time of an interval during which an option can be exercised.

`opdDeposit` denotes the tokens which the option buyer would get by paying the `opdPayment` tokens where the price of one `opdDeposit` token, in terms of `opdPayment` tokens is `opdPrice`. I.e., if `opdPrice` is denoted by $P$, then the price of one `opdDeposit` token is equal to $P$ `opdPayment` tokens.

Remaining variables, namely, `opdRef`, `opdToken` & `opdSellerKey` are explained shortly.

After option writer has decided on the fields, writer now mints _option tokens_ where _anyone_ holding such an option token has the right to exercise the option within execution interval, thus option writer would sell these tokens against the desired premium and afterwards these tokens could trade in DEX just like any other token. This minting is governed by `mkOptionPolicy` which takes in two parameters, currency symbol of the NFT (more on this later) & address of the options validator. Let us first see the conditions for minting under `mkOptionPolicy` before moving on to understand about role of options validator.

* If non positive mint occurs then there is no further condition, thus burning is always allowed.
* If mint is positive, then:
  * The transaction must consume a UTxO whose reference is given by the redeemer of this contract. Thus, the redeemer to contract is of type `TxOutRef` (reference to an UTxO). Let us denote this given reference as $r$.
    * This same UTxO (with reference $r$) is also used to mint the NFT, where minting policy of this NFT token is given [here](https://github.com/geniusyield/Core/tree/main/geniusyield-onchain/src/GeniusYield/OnChain/DEX#nft). Now as our NFT's minting policy isn't parameterized, we know it's currency symbol, and since the token name has to be the hash of this given $r$, we know the complete asset class of our NFT token. Purpose of this NFT is to track & link different states of this particular option in our options validator, this would become clearer once we see workings of options validator contract.
  * The transaction must mint tokens with currency symbol corresponding to that of `mkOptionPolicy` and all of them must have token name as the hash of this $r$.
  * The transaction must deposit the minted NFT and the sufficient number of `opdDeposit` tokens to the address of options validator contract. Here sufficiency of `opdDeposit` tokens is in the regard that their amount must be greater or equal (it wouldn't help option writer anymore to send greater _than_ equal) than the number of option tokens minted in this transaction.
    * Since every UTxO in Cardano requires some amount of ada to be valid, we check the sufficiency of the given deposit is without this minimum ada, which we currently fix as 3 ada.
    * We insist that there is only one output to our validator's address in this transaction.
  * The datum of the output at validator's address must have `opdRef` as the reference of the UTxO being consumed here to mint both NFT & option tokens. And `opdToken`, which denotes the asset class of minted option tokens must have the currency symbol of this `mkOptionPolicy` and token name as verified earlier being the hash of the `opdRef`.

Now, let us understand the workings of `mkOptionValidator` (options validator smart contract) which governs the logic around exercising of option tokens.

This contract is also parameterized by the currency symbol of our NFT minting policy. It's datum as remarked earlier, is of type `OptionDatum` and redeemer is of type `OptionRedeemer` (fields explained afterwards):

```haskell
data OptionRedeemer =
      Execute Integer -- ^ Execute the given number of option tokens during the execution interval.
    | Retrieve        -- ^ Retrieve payment tokens and remaining deposit tokens after the execution interval has passed.
```

Thus, there are two actions for this smart contract:-

* `Retrieve`: This action is to be executed by option writer after the expiry of option tokens. It checks for the following conditions:-
  * Option tokens can no longer be exercised, i.e., current time is greater than `opdEnd`.
  * NFT token must be burnt.
  * Transaction must be signed by seller, i.e., signature must exist for the public key `opdSellerKey`. This explains the purpose of `opdSellerKey`.
    * Due to uniqueness of NFT, two transactions can't be satisfied by the burning of one NFT.
* `Execute amount`: This action is to be executed by option buyer, where they will use their option tokens in `1 : 1` ratio to the number of `opdDeposit` tokens they want to obtain. Conditions to satisfy in this case:-
  * Current time must be within `opdStart` & `opdEnd` (inclusive).
  * Given `amount` of `opdToken` are burnt.
  * NFT must be passed along the continuing output (i.e. newly created output at validator's address) and the datum in this output must be same as current UTxO being consumed.
    * Here we again enforce that there is only one output to validator's address in this transaction.
  * The amount of `opdDeposit` taken is not more than `amount`.
  * The extra value of `opdPrice * amount` (we check for at least this amount, one could pay more but it's at their cost) is paid for in continuing output.

[^1]: Assuming American option, options are also classified as American or European based on the timing of their execution. American options can be executed at any time before the expiration date, providing flexibility for the holder. European options, on the other hand, can only be executed on the expiration date, which requires careful timing and strategy. Our options contract support both as execution interval can be set arbitrarily.
