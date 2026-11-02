# THAW

English | [中文](README.zh-CN.md)

**Unaudited. Not deployed on BSC mainnet.** This repository is source code only. It is not a live token and it makes no promise about price or outcome. Audit it before any mainnet use.

THAW is an ownerless fair-mint ERC-20 on BNB Smart Chain that only addresses holding an Agent ID can mint. The mint is priced in tiers. Once the targets are met, anyone can open the pool, and the LP tokens are sent to a burn address. There is no reserved allocation, no pause, no blacklist and no upgrade path. At pool opening, a hard-coded share (10%) of the raised BNB goes to the developer address and the rest goes into the liquidity pool. Nobody can change that share, and nobody can withdraw the remaining BNB.

This repository covers local tests, BSC mainnet fork tests and script simulations. The generic script `script/Deploy.s.sol` reverts on chain ID 56 when a private key is set. Mainnet deployment goes only through `script/DeployMainnet.s.sol` (chain 56), signed with a hardware wallet or an encrypted keystore; plaintext private keys are rejected. See [DEPLOY_MAINNET.md](DEPLOY_MAINNET.md).

## Mechanics

### Mint

First come, first served, in three price tiers that by default cover 25% / 50% / 25% of the hard cap:

| Tier | Share | Default price |
| --- | --- | --- |
| 1 | 25% of the hard cap | 0.004 BNB / share |
| 2 | 50% of the hard cap | 0.005 BNB / share |
| 3 | the remainder | 0.006 BNB / share |

Default hard cap 30,000 shares, soft cap 1,000 shares, window 48 hours. Each wallet can buy at most 5 shares during the sale. Each Agent ID can mint at most 5 shares over its lifetime; sale mints and post-open mints count together, and the limit does not reset daily. A single purchase can span tiers; `quote` sums across tiers. `msg.value` must equal the quote exactly; paying more or less reverts.

Each share carries a fixed number of tokens (default 3,000). Cheaper tiers get the same number of tokens, so their cost is lower.

Only addresses holding a `.ai` Agent ID from Binance Agentic Wallet can mint. The verifier address is fixed at deployment. Contract callers are rejected, but EIP-7702 delegated accounts pass: code length exactly 23 bytes, starting with `0xef0100` (followed by the 20-byte delegate address). This is the check the spec calls for, not a hidden switch.

### Soft cap not reached

After the window ends, if fewer shares than the soft cap were sold, anyone can call `triggerRefund()`. Each minter calls `refund()` to get back all the BNB they paid, with no fee. Once in refund mode, the pool can no longer be opened and the developer address receives no mint fee.

### Pool opening

Once the hard cap is filled, or the window has ended with the soft cap reached, anyone can call `finalize()`.

- Minters receive `T = shares sold × tokens per share` in total.
- `mintFeeBps` (default 10%) of the raised BNB goes to the immutable developer address. The rest (default 90%) goes into the pair.
- The token amount paired with that 90% is computed so that the opening price is still "premium × average mint cost over the full raise". The default premium is 3/2, so the opening price is 1.5× the average cost, not 1.5× minus 10%.
- LP tokens are minted to `0x000000000000000000000000000000000000dEaD`.
- The router's `addLiquidity` is not used. The contract transfers WBNB and tokens directly into the factory-created pair and calls `mint`.
- If someone pre-creates the pair, donates WBNB and calls `sync`, pool opening tops up tokens against the post-donation WBNB balance so the price still lands on target. Donations without `sync` are `skim`med to the burn address. Tokens cannot be transferred before pool opening, so the token side cannot be donated.

### Minting after pool opening

Shares left unsold under the hard cap can still be minted after pool opening, until `sold == hardCap`. Once the cap is filled, supply is permanently fixed.

The price is neither a tier price nor the pair's spot price. Price per share = `tokens per share × TWAP`. The TWAP reads the PancakeSwap V2 pair's own cumulative prices (`price0CumulativeLast` / `price1CumulativeLast`), with a default window of 30 minutes. After pool opening, minting waits until the first full window has elapsed. Dumping or pumping and then minting in the same transaction cannot move this average: when the pair has already updated its reserves in the current block, the new price contributes 0 seconds to the cumulative value. There is also a cheap guard: if the spot price deviates from the TWAP by more than `twapMaxDeviationBps` (default 10%), the mint reverts, so nobody can pump the spot price, mint at the stale average and sell back into the pool.

TWAP reference point: the contract keeps a 4-slot ring buffer of the pair's cumulative-price checkpoints, written at most once per half window (`ceil(twapWindow/2)`, default 15 minutes). Transfers, `poke` and mints all try to write one, but before the interval has passed they read a single storage slot and return, so the extra cost per transfer is constant. Pricing uses the most recent checkpoint that is at least one full window old and averages from it to now. The 4 checkpoints are at least half a window apart, so the third-most-recent one is always at least a full window old; however frequent the trading, the reference point cannot be refreshed too recently to block minting (the old version had this problem; see the testnet notes below). With continuous trading, the averaging interval is between 1 and about 1.5 windows. If nobody touches the contract for a long time, the interval gets longer (still an on-chain cumulative average that a single block cannot push), and if the average is clearly stale, the spot-deviation guard above rejects the mint. Pumping the price k× in a single block shifts the average by about `(k−1) × block seconds / window seconds`; dumping shifts it by at most `block seconds / window seconds` (about 0.17%), because the price cannot go below 0.

`quoteOpen` reads exactly the same way as `mint` in the same block (read the price first, then write the checkpoint), so the quote is what a same-block mint charges.

Payment: `msg.value` is the buyer's maximum and must be at least the TWAP cost, otherwise the call reverts with `WrongPayment(cost, paid)`. Only the cost is charged: 10% of it goes to the developer address, and 90% is added to the pool together with newly minted tokens at the current reserve ratio, so this liquidity add does not move the price. LP still goes to the burn address. Any overpayment is refunded to the caller at the end of the same transaction (all state is updated first, the transfer happens last, and the reentrancy lock is still held). The website sends "quote + 1%" and shows the amount charged and refunded.

Minters receive `tokens per share × shares` immediately; these tokens are not locked and not subject to forfeiture. Only Agent IDs can mint.

### Unlocking

Of the tokens from the sale, 15% (default) can be claimed with `claim()` right at pool opening; the rest is locked. `claim` needs no approval. Tokens minted after pool opening are not part of this 15%; they are unlocked from the start.

Demand unlock: only net buys (buys minus sells) on the official pair count, and the high-water mark is committed only in a later block. Every 100 tokens of net buying unlocks 50 tokens of locked supply, distributed pro rata to locked balances at that time. Buying and then selling in the same transaction does not raise the high-water mark to that transaction's gross buy.

Time floor: from day 7 after pool opening, remaining locked tokens release linearly over 7 days and are fully claimable on day 14. Do not read this as a 21-day window.

### Sell forfeiture (within 14 days, decaying rate)

For the first 3 days after pool opening, the forfeiture multiplier is 100%. From day 3 to day 14 it decreases linearly to 0. At exactly day 14 and after, it is 0.

When a minter sells or transfers X% of their claimed sale tokens, `X% × current multiplier` of their still-locked balance is forfeited. The denominator of X% is only this bucket of "claimed and not yet transferred" sale tokens. Tokens minted after pool opening, tokens bought from the pair and tokens received from others are tracked in a separate free balance, which is spent first on transfer and does not trigger forfeiture. Transfers to yourself are not sales. Receiving tokens never increases your locked balance.

Forfeited tokens are distributed to other holders that still have locked tokens, pro rata to their remaining locked balances. The seller does not get any of that forfeiture back. If no other holder still has locked tokens after the forfeiture, the forfeited tokens are burned. With more than 6 holders, time unlocks and forfeiture redistribution use a global index, so one transfer only touches the seller, the buyer and global variables; with 6 or fewer, they are settled per holder in integers and match the reference model. Fractions below the minimum unit that cannot be distributed yet are first removed from the locked balance (so dust-splitting cannot dodge forfeiture) and distributed once they add up to the minimum unit; any fraction still undistributable at the end of the window is burned.

After day 14, forfeiture stops. The token is then a plain ERC-20 with a fixed tax.

### Tax

A 3% tax applies only to buys and sells on the official PancakeSwap V2 pair; wallet-to-wallet transfers are not taxed. The 3% is a constant that the constructor cannot change: 1.5% accumulates up to a threshold and is swapped to BNB for the immutable developer address, and 1.5% is auto-added to the liquidity pool with the LP sent to the burn address. The swap is wrapped in `try/catch`, so a failed swap does not revert the user's sell.

Sells must go through the router's `swapExactTokensForETHSupportingFeeOnTransferTokens`. The non-fee-supporting `swapExactTokensForETH` fails because the pair receives less than expected. Users only need to approve the official router. Mint, claim and refund need no approval.

## Default parameters

All fixed at deployment and immutable afterwards. The deploy script overrides them via environment variables; the defaults are below. The mainnet script `script/DeployMainnet.s.sol` pins its own values (for example a 2,000-share soft cap and a 72-hour window) and reverts on any mismatch; see [DEPLOY_MAINNET.md](DEPLOY_MAINNET.md).

| Parameter | Default |
| --- | --- |
| Hard cap / soft cap | 30,000 / 1,000 shares |
| Tier prices | 0.004 / 0.005 / 0.006 BNB |
| Tier shares | 25% / 50% / remainder |
| Per-wallet sale limit | 5 shares |
| Per-Agent-ID lifetime limit | 5 shares (sale + post-open mints) |
| Mint window | 48 hours |
| Tokens per share | 3,000 (18 decimals) |
| Opening premium | 3/2 (opening price = 1.5 × average mint cost) |
| Mint fee | 10% to the developer address, 90% to the liquidity pool |
| Post-open price | 30-minute TWAP; rejected if spot deviates by more than 10% |
| Sale tokens claimable at opening | 15% |
| Demand unlock | 50 locked tokens per 100 tokens net bought |
| Time cliff / linear release | 7 days / 7 days (fully released on day 14) |
| Full forfeiture period / forfeiture window | 3 days / 14 days |
| Tax | 3% = 1.5% developer + 1.5% liquidity (constant, not a parameter) |
| Swap threshold / minimum unit | 3,000 tokens / 1e12 wei |
| Router / factory / WBNB | PancakeSwap V2 mainnet addresses, see below |
| Agent ID registry | `0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F` |

## Checking for backdoors on BscScan

After deployment, ignore any website and check the source against this list:

1. The source exactly matches `src/FairToken.sol` in this repository (BscScan / Sourcify exact match), compiler 0.8.28, optimizer on.
2. The contract has no `owner`, `onlyOwner`, `upgrade`, `pause`, `blacklist` or admin `mint` entry point. `pair` is written once, only in `finalize`, from the factory's `getPair` / `createPair`.
3. The constructor arguments use router `0x10ED43C718714eb63d5aA57B78B54704E256024E`, factory `0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73` and WBNB `0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c`. You can cross-check with the router's `factory()` and `WETH()` on chain.
4. The verifier is `AgentIdVerifier`, and its `registry()` is the Agent ID registry above, not some replaceable address.
5. The developer address is one you have approved in advance. Tax goes there permanently and no function can change it.
6. Read `TAX_BPS` (300), `DEV_BPS` (150) and `LP_BPS` (150). These three are constants.
7. Search the source for `transfer` / `call{value`: BNB moves only in `refund` (back to the payer), in the fixed-ratio fee at pool opening and on post-open mints (to the immutable developer address), when wrapping WBNB, and during swaps. There is no admin withdrawal function.
8. After the `Finalized` event, the LP token holder should be the burn address and this contract's LP balance should be 0.

## Agent ID: verified and not verified

Verified with read-only calls on BSC mainnet (no transactions sent):

- Registry `0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F` has code, `name()` is `SPACE ID Agent ID`, `symbol()` is `AI`, and `supportsInterface(0x80ac58cd)` is true.
- `ownerOfHandle("binance")` = `0x5E3fBbc8D260a63C9fe19CbBb0A9d5792C3375eA`, the reverse `handleOf` is also `binance`, `balanceOf` is 1, and that address has code length 0.
- `ownerOf(keccak256("binance"))` matches the holder above, so using `keccak256(handle)` as the identity key equals the on-chain tokenId. Another registered address was spot-checked and also has code length 0.
- Simulating `transferFrom` / `approve` / `setApprovalForAll` from the holder reverts with `Soulbound`.

The adapter therefore checks two things: `handleOf` is non-empty, and `ownerOfHandle` points back to the same address; the identity key is `keccak256(handle)`. Tests use a mock and do not depend on the mainnet registry.

Not mathematically proven; things to know when using it:

- In the public interface, `handleOf` returns a single string. The spot-checked holder has `balanceOf == 1`. The full registry was not scanned to prove that no address can have a balance above 1. Given the current interface and soulbinding, there is one ID per wallet, so today the per-ID limit and the per-wallet limit are the same thing.
- The registry itself has `owner`, `signer` and `adminRegister`. Those are SPACE ID / Binance issuance rights, not admin rights over this token. They decide who can get an ID.
- The spot-checked Agent wallets are externally owned accounts. If Binance later moves to ordinary smart-contract wallets (code that is not a 23-byte 7702 delegation), `mint` will reject them. 7702 delegations pass per the spec. No 7702 code has been seen on the two sample addresses on mainnet so far.

## Build and test

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation).

```bash
forge install foundry-rs/forge-std
forge test --no-match-contract FairTokenForkTest
forge test --match-contract FairTokenForkTest
```

Fork tests connect to a public BSC RPC (default `https://bsc-dataseed.bnbchain.org`), read mainnet state only and execute locally without broadcasting. You can also run your own fork node:

```bash
anvil --fork-url https://bsc-dataseed.bnbchain.org
```

The generic deploy script `Deploy.s.sol` only simulates; mainnet broadcasting is blocked (mainnet uses `DeployMainnet.s.sol` with a hardware wallet or keystore):

```bash
# Reverts: chain id 56 with DEPLOYER_KEY set
forge script script/Deploy.s.sol --fork-url https://bsc-dataseed.bnbchain.org
```

Parameters can be overridden with environment variables: `DEV_WALLET`, `HARD_CAP`, `SOFT_CAP`, `TIER1_PRICE`, `TIER2_PRICE`, `TIER3_PRICE`, `TIER1_BPS`, `TIER2_BPS`, `MAX_PER_WALLET`, `MAX_PER_IDENTITY`, `MINT_DURATION`, `TOKENS_PER_SHARE`, `PREMIUM_NUM`, `PREMIUM_DEN`, `IMMEDIATE_BPS`, `DEMAND_NUM`, `DEMAND_DEN`, `VEST_CLIFF`, `VEST_LINEAR`, `FORFEIT_FULL_RATE`, `FORFEIT_WINDOW`, `SWAP_THRESHOLD`, `MIN_UNIT`, `ROUTER`, `FACTORY`, `WBNB`, `AGENT_REGISTRY`, `TOKEN_NAME`, `TOKEN_SYMBOL`. Never commit a real private key.

## Test results (as recorded)

- Unit and fuzz: 23 tests in `FairToken.t.sol`, including 2 fuzz tests at 128 runs each. They cover minting, cross-tier quotes, wallet and identity limits, 7702, refunds and refund reentrancy, opening price, pre-created pairs, synced and unsynced WBNB donations, rejected token donations, rejected direct BNB transfers, the forfeiture curve (day 3, midpoint, day 14), dust-splitting not escaping forfeiture, forfeiture redistribution, next-block commit of demand unlocks, same-transaction buy/sell not raising the high-water mark, linear release from day 7 to day 14, buy/sell tax, tax-free wallet transfers, failed swaps not breaking sells, and successful swaps paying the developer and burning LP.
- Invariants: 5, at 32 runs × depth 20 (640 calls). Lock ledger `pool + vested + burned + earmark == initialPool`; the contract's token balance equals unclaimed mint amount plus tax inventory; total supply equals minted amount plus LP mints minus burns; raised BNB does not stay in the token contract after pool opening; the forfeiture curve is still 100% on day 3, 50% at the midpoint and 0 on day 14.
- Mainnet fork: real router / factory / WBNB / Agent ID registry. The holder of the `binance` ID can mint and an address without an ID cannot; pool opening still works after a WBNB donation plus `sync`, with the price within one integer division; then a real-router buy, a sell via the fee-supporting function, day-3 forfeiture and a zero multiplier on day 14.
- Coverage (excluding fork): `FairToken.sol` lines 87.78% (431/491), statements 82.02% (666/812), branches 49.19% (91/185), functions 87.80% (36/41). Branch coverage is lower mainly because of constructor-parameter failure branches and some unreachable extreme-donation branches.
- Slither (excluding `test/` and `lib/`, informational included): see the next sections. No unexplained high-severity findings remain.
- Deployment size: runtime code once grew to 29,229 bytes, above the EIP-170 limit of 24,576, and could not be deployed. It is now split as described in "Code layout": `FairToken` runtime 22,925 bytes, `FairTokenExt` 18,278 bytes, `FairTokenParams` library 3,054 bytes; `FairToken` init code 47,154 bytes (about 48,340 with constructor arguments; EIP-3860 limit 49,152). `test/Size.t.sol` asserts these limits.
- Gas (before split → after split → after adding the TWAP checkpoint ring): opening with 6,000 holders 1,538,396 → 1,542,190 → 1,542,312; first claim 276,471 → 277,269 → 268,050; transfer that triggers forfeiture 310,807 → 315,229 → 306,032; day-10 claim 361,774 → 362,865 → 353,135. Transfers and claims got cheaper because the TWAP observation is no longer written on every transfer, only at most once per half window. Measured deployment gas 6,537,037 → 9,158,054 → 9,202,113.
- 71 tests in total, all passing: the original 62 unchanged; 3 size/permission tests; 6 post-open mint tests (minting still works after 4 hours of high-frequency activity, exact overpayment refund, underpayment reverts, a single-block 10× pump moves the TWAP by < 2%, a single-block dump moves it by < 0.25% and is rejected by the spot guard, the checkpoint ring always has a sufficiently old reference point). The high-frequency, overpayment and checkpoint-ring tests fail on the old implementation.
- At the time, BSC mainnet `eth_gasPrice` (`bsc-dataseed.bnbchain.org` and `bsc.publicnode.com`) was 50,000,000 wei, i.e. 0.05 gwei. Deployment cost was about `4,079,948 × 50,000,000 = 203,997,400,000,000 wei`, about 0.000204 BNB. This is the gas price read at the time, not a quote.
- Refund and pool opening were then run end to end on BSC testnet (chain 97) with a throwaway testnet key. Mainnet is still not deployed. Addresses and transactions are in the testnet section.

## Code layout (for auditors)

The split only moves code; it does not change logic:

- `src/FairTokenBase.sol` (abstract): all storage, immutables, internal functions and events, moved verbatim from the original `FairToken.sol`. Errors are now file-level declarations; `FairToken` redeclares them under the same names, so `FairToken.X.selector` in tests is unchanged and errors with the same name appear twice in the ABI (same selector, harmless).
- `src/FairToken.sol`: the entry contract. External function signatures, selectors, storage layout and events are unchanged. A read-only `extension()` was added. The bodies of `finalize`, post-open `mint` (the post-open branch), `noteSale` and `flushEarmarkAll` moved to the extension contract; the entry contract only forwards via `delegatecall`, and revert data bubbles up unchanged.
- `src/FairTokenExt.sol`: created with `new` in the `FairToken` constructor, at an immutable address. It inherits the same `FairTokenBase`, so storage slots are identical; it can only be called by its token via `delegatecall` (`onlyToken`), and direct calls revert with `Forbidden`.
- `src/FairTokenParams.sol`: an external linked library holding the constructor parameter checks, moved verbatim (same `InvalidParams("...")` messages). The library must be deployed or linked before deployment.
- `name` / `symbol` are assigned in the `FairToken` constructor, which keeps the extension's init code smaller.

After the split there are two intentional logic changes (post-open minting only): TWAP observations now use a 4-slot checkpoint ring (`twapObsTs` / `twapObsCum` / `twapObsHead` replace `twapOlderTs` / `twapNewerTs` / `twapOlderCum` / `twapNewerCum`), and `_mintOpen` reads the price before writing the checkpoint; `_mintOpen` accepts `msg.value >= cost`, distributes the fee and liquidity add based on cost, and refunds any overpayment at the end, with `OpenMinted.paid` recording the cost. The sale phase still requires exact payment.

## BSC testnet (chain 97)

This is not a mainnet deployment. Parameters were scaled down to what a testnet balance can pay: 0.0001 / 0.00012 / 0.00015 tBNB per share, hard cap 8 shares, soft cap 4 shares, a 5-minute mint window, and locking and forfeiture in minutes instead of days. These durations are constructor parameters; the production contract logic was not changed for testnet.

PancakeSwap V2 testnet router `0xD99D1c33F9fC3444f8101754aBC46c52416550D1`. Its on-chain `factory()` is `0x6725F303b657a9451d8BA641348b6761A6CC7a17` and `WETH()` is `0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd`.

Current (deployed 2026-11-02 05:51 SGT, with the TWAP checkpoint ring and overpayment refund):

| Contract | Address |
| --- | --- |
| MockHandleRegistry | `0xb27eB336B109c32C454d1874360952d8444bcf6B` |
| AgentIdVerifier | `0xe54D12732Fd90c03E09DCB326E0bDB2b5D071f30` |
| FairTokenParams (library) | `0x2DeF7c6f02BA9166BA74dA6853afCEbC58E8a12c` |
| FairToken from the pool-opening run (used by the website) | `0xa80EeBDaCA755E9a60865c8533E8aC71E1515d93` |
| Its FairTokenExt | `0xAbe566b806508d3a2d4Bc0581Fc86C8dE07DB65b` |
| FairToken from the refund run | `0x3142990cC537d12238C92Efa24aD6a5d4D3f565e` |
| Its FairTokenExt | `0xBb0574CdD03010D71cAa9D545265f6e1C316160B` |

Pool-opening pair `0x7d5688b377A2d3EB46da0B474Daffc7Ba7512096`. Two test Agents are registered: the deployer and a throwaway test wallet `0x35b178f4eDcba37DE3A2B1600d4d13cC67Faf1D5`. Smoke-test transactions (times in SGT):

| Step | Transaction |
| --- | --- |
| mint(4) (sale) | `0x01259d4094beb48d754430ae3c02a9439621edc259dc57ab70989b595d46ebaa` |
| finalize 05:56:35 | `0x89083980a169dbdd08720d3919475f28387258604cf5e77e61ae1858eb2e8d7c` |
| claim | `0xbcfc50f1578d8f93948d170da7457a65075d353187abc800d21ae9a45eb29edf` |
| Post-open mint, 1 share (agent2, right after poke/transfer/trade activity), 1% overpayment refunded | `0x08483ea3bb655860e738e30b8ce5d340ebc97967160b1e2710c09d12ba032fec` |
| Post-open mint, 2 shares (agent2) | `0xbafcc2207e2bed13f7c582bb9c4aff2f01e47e5b0d2dbe59667ca9fc46bd9058` |
| Post-open mint, 1 share (deployer), hard cap of 8 shares filled | `0x773dd2038f4560e0899bf99cff7c0c330ae5cb953a414e3b9503f768afcab03a` |
| Refund run: mint(1) | `0xff1b8fe5b68bddccd7223b0f7a299bd2a0d9b7ec802f7fb971d569542ee59461` |
| Refund run: triggerRefund | `0xf408e54745f1396faf4d1c46ad246cbebddb04ec8e9b54279fb90a6c12d6cf3f` |
| Refund run: refund | `0xec113a768c117c687244e6bc230cb6daed188734a5c6d49f2f8f9ccc68a7e90b` |

For about 45 minutes after pool opening, a poke, transfer or small trade was sent every 5–7 seconds (about 345 transactions, all successful). `quoteOpen` stayed usable throughout and all three post-open mints succeeded; each overpayment was refunded exactly per `OpenMinted.paid` (e.g. the first one: sent 1,081,507,876,571,940 wei, charged 1,070,826,660,330,000, refunded 10,681,216,241,940). A simulated underpaying call reverted with `WrongPayment`. The token contract's BNB balance was unchanged before and after the mints.

One `TwapDeviation` was also observed during the smoke test: for the first 30 minutes the activity script bought 0.00002 tBNB on every 4th transaction while the pool held only about 0.0004 tBNB, pushing the spot price to 2× the TWAP, and the spot guard rejected the mint as designed. After switching to balanced buy/sell activity and one sell-back to bring the spot price near the TWAP, minting succeeded. When the price moves quickly in one direction (more than `twapMaxDeviationBps` within 30 minutes), post-open minting is temporarily rejected by the guard; this is an intentional trade-off.

Fixed (2026-11-02): the old `mint` observed before reading the TWAP, so frequent transfers kept the reference point too recent and caused long `TwapNotReady` periods (as in the old testnet run at 05:09 SGT); the old version also required exact payment, so any quote change caused `WrongPayment`. Now it uses the checkpoint ring plus overpayment refund; see "Minting after pool opening" above.

All contracts above are a match on Sourcify. BscScan's verification API requires an API key, which was not available this time, so the testnet BscScan pages may still show them as unverified. Sourcify records: `https://sourcify.dev/server/v2/contract/97/<address>`.

Earlier testnet deployments are deprecated. After the split, before the fix: registry `0xb5D3EfD26556b93Ac46499294B575944EdFf2090`, verifier `0x2D676E62aF0EcBE3e7617142A07304a6d04249De`, library `0xAE5963DBB78fa5fe4b168926A9357F777205bDF0`, tokens `0xcdeB8D208C46f14a825D1d51E9207caDECd79390` / `0xD08D4ecF98B55523Af3cD9016009fD8dc2ff21E6`. Before the split: registry `0x0D771114F245508B4B75C764B1112402f0358Eae`, verifier `0x66454DA1e0C09AABAdbD34BC54D655F44185Fb9F`, tokens `0x9f6d650439b6706dDEE010FaD30D41c7d871247D` / `0xDd2377bd797c8E14704b1c58E6703A86f0525b8D`.

## Security properties (self-review)

| Threat | Handling |
| --- | --- |
| Front-running / Sybil | Only Agent IDs can mint, with limits per wallet and per ID. If IDs themselves can be obtained in bulk, the limits cannot stop one person with many accounts. That depends on the registry's issuance policy, not on this contract. |
| Flash loans inflating net buys | The high-water mark is committed only in a later block. Buys within the same transaction are not yet in the high-water mark, and a following sell offsets them. The next block commits the net amount, not the intermediate peak. The protocol's own swaps and liquidity adds are recorded as sells, so tax does not inflate unlocks. |
| Pre-seeding the pair | The token cannot be transferred before pool opening. If a WBNB donation has been `sync`ed, tokens are topped up against the post-donation balance so the price still equals the target; unsynced donations are `skim`med to the burn address. `addLiquidity` is not used, so the "dirty reserves make the router revert" path does not exist. With an extremely large donation whose product overflows `uint256`, pool opening reverts; this requires more WBNB than actually exists and is not treated as an actionable attack. |
| Swap reentrancy | During `inSwap`, only the contract's own transfers go through and all others revert, so the developer address's `receive` cannot use the swap to turn a sell into a tax-free one. User sells are also wrapped in `try/catch`. `refund` updates accounting before sending BNB and holds a reentrancy lock. |
| Rounding | Everything rounds down. Forfeiture accumulates with 512-bit mul-div; any wei owed is immediately removed from the locked balance, so splitting a sell into dust cannot escape it. Distribution to others is batched by `minUnit`, and anything undistributable is burned at the end of the window. Forfeiture by a sole holder is burned, to avoid "forfeit and then get it back pro rata". |
| 7702 | Only 23-byte code with the `0xef0100` prefix passes. A contract deliberately shaped as those 23 bytes would also pass; this is a residual risk of the spec's choice, and passing grants it no extra privileges. |
| Fee-on-transfer and the router | Sells must use `swapExactTokensForETHSupportingFeeOnTransferTokens`. Buys can use plain `swapExactETHForTokens`, because the tax is taken after tokens leave the pair. Tested on a local mini router and on the real router on a mainnet fork. |
| Agent wallet compatibility | See the previous section. Current samples are externally owned accounts. Non-7702 contract wallets cannot mint. The registry admin can issue IDs; that is external trust, not a backdoor in this contract. |

Slither findings:

- `arbitrary-send-eth`: `addLiquidityETH` sends freshly swapped BNB to the immutable router, and the LP recipient is the burn-address constant. Raised funds are not sent to an arbitrary address.
- `incorrect-exp`: the `^` in `FullMath` is XOR used in the Newton iteration, not exponentiation. False positive.
- `reentrancy-eth` (`finalize`): accounting and `launched` are written before external calls, and the function holds a reentrancy lock. `inFinalize` is true during the call and cleared only afterwards.
- `reentrancy-no-eth` (swap): `inSwap` makes non-contract transfers revert, and the reserve is zeroed only after the outer call succeeds.
- `divide-before-multiply` / `incorrect-equality`: intentional rounding down, and exact sentinels for "rate is 0 / progress is 100%".
- `timestamp`: windows, unlocks and forfeiture are time-based by design. Informational.
- Assembly: `extcodesize` and `mulDiv`. Informational.

Known and not fixed in this contract: if the developer address is wrong, the 1.5% goes to the wrong place forever; there is no pause, so an implementation bug cannot be frozen on chain; swaps can be sandwiched; LP in the burn address cannot be recovered by anyone, by design.

## Before mainnet

1. Have someone else or an auditor review `src/FairToken.sol` again. The self-review in this file is not an audit.
2. Choose the developer address (an externally owned account is recommended). It cannot be changed once written into the constructor arguments.
3. Reconfirm that the Agent ID registry is still `0x60B9…022F` and that the router / factory / WBNB are still the three addresses above.
4. Verify with exact source from this repository, not a web copy that "looks the same".
5. Deployment must be done by a person, off-chain. The generic script refuses to broadcast on chain ID 56. Do not remove that revert to hand a private key to automation for convenience.
6. Mainnet deployment steps are in [DEPLOY_MAINNET.md](DEPLOY_MAINNET.md).

## License

MIT. See [LICENSE](LICENSE).
