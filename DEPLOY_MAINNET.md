# THAW mainnet deployment (BSC, chain 56)

English | [中文](DEPLOY_MAINNET.zh-CN.md)

Script: `script/DeployMainnet.s.sol`. The contract source (`src/`) is not changed. No private keys are kept in the repository, and none in `.env` either. The script reverts if any of `DEPLOYER_KEY` / `PRIVATE_KEY` / `ETH_PRIVATE_KEY` / `MAINNET_KEY` is non-empty. Signing uses only a hardware wallet (`--ledger` / `--trezor`) or an encrypted keystore (`--account`).

## Parameters pinned by the script

| Parameter | Value |
|---|---|
| Hard cap / soft cap | 30,000 / 2,000 shares |
| Tokens per share | 3,000 THAW |
| Price tiers | 1–7,500: 0.004 BNB; 7,501–22,500: 0.005 BNB; 22,501–30,000: 0.006 BNB |
| Per wallet (sale) / per Agent ID (lifetime) | 5 / 5 shares |
| Sale window | 72 hours (`deadline = deploy block timestamp + 259200`) |
| Opening price | average cost × 3/2 |
| Mint BNB split | 10% project wallet / 90% liquidity pool |
| Unlocking | 15% at opening; demand unlock 1:2; cliff 604800 s + linear 604800 s |
| Forfeiture | 100% for the first 259200 s, decreasing linearly to 0 at 1209600 s |
| Post-open minting | TWAP window 1800 s, max deviation 10% |
| Swap threshold / minimum unit | 3,000 THAW / 1e12 |
| Router / factory / WBNB | `0x10ED…024E` / `0xcA14…0c73` / `0xbb4C…095c` |
| Agent ID registry | `0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F` |
| Project wallet (immutable) | `0xb96401CD93006eb68A86Ee2006fd3f4B85e32045` |
| Deployer (`--sender`) | `0x57287D08B85793A3d0be9908d2696Fab37371Eb8` |

If any parameter differs from the table, the script reverts. Parameters can only be changed by editing the script constants and starting again from step 1. The signing address must be the deployer above. If the hardware wallet address changes, update `DEPLOYER` in the script and rerun steps 1–2.

Note: the tier 3 price is exactly 1.5× the tier 1 price (0.006 = 1.5 × 0.004), not strictly less. The script also strictly checks that whenever tier 2 or tier 3 has sales, the overall average cost × 1.5 is above that tier's unit price.

## 1. Test (off chain)

```bash
forge build
forge test --no-match-contract "ForkTest"
BSC_RPC_URL=https://bsc-rpc.publicnode.com forge test --match-contract "ForkTest"
```

`DeployMainnetForkTest` runs the deploy script on a mainnet fork and covers:
- parameter readback;
- no owner / no admin functions;
- pool opening at the soft cap, with 10% to the project wallet and 90% to the pool;
- all LP at `0x…dEaD` except PancakeSwap's 1000 wei;
- opening price at 1.5×;
- TWAP minting and overpayment refund;
- full refund below the soft cap;
- pool opening after 6,000 IDs fill the hard cap (measured finalize about 3.94M gas, including createPair).

## 2. Simulate the deployment (without `--broadcast`)

```bash
forge script script/DeployMainnet.s.sol:DeployMainnet \
  --rpc-url https://bsc-dataseed.bnbchain.org \
  --sender 0x57287D08B85793A3d0be9908d2696Fab37371Eb8
```

The last log line should be `all post-deploy checks passed`. There are 3 transactions:
1. CREATE2 deployment of the `FairTokenParams` library at `0x2DeF7c6f02BA9166BA74dA6853afCEbC58E8a12c`;
2. `AgentIdVerifier`;
3. `FairToken`.

Expect about 13.2M gas, about 0.00066 BNB at 0.05 gwei. The actual cost depends on the gas price at the time; keep at least 0.003 BNB in the deployer.

## 3. Broadcast (run by the hardware wallet holder on their own computer)

```bash
# Ledger: unlock, open the Ethereum app and enable blind signing (needed for contract deployment)
forge script script/DeployMainnet.s.sol:DeployMainnet \
  --rpc-url https://bsc-dataseed.bnbchain.org \
  --ledger --sender 0x57287D08B85793A3d0be9908d2696Fab37371Eb8 \
  --broadcast --slow
```

For Trezor, replace `--ledger` with `--trezor`. For an encrypted keystore, use `--account <name>` instead (import it first with `cast wallet import <name> --interactive`; the private key stays encrypted on the local machine only).

Confirm every transaction on the device. `--slow` waits for each transaction to confirm before sending the next. Record the `verifier`, `token` and `extension` addresses from the output.

## 4. On-chain readback (read only)

Run this immediately, before the first mint:

```bash
forge script script/DeployMainnet.s.sol:CheckMainnetDeployment \
  --sig "run(address)" <token address> --rpc-url https://bsc-dataseed.bnbchain.org
```

It should print `on-chain readback matches approved params`. Then check `deadline()` on BscScan; it should equal the deployment transaction's block timestamp + 259200.

## 5. Source verification

```bash
# Sourcify (no API key needed)
forge verify-contract <library address 0x2DeF…> src/FairTokenParams.sol:FairTokenParams --chain 56 --verifier sourcify
forge verify-contract <verifier> src/verifiers/AgentIdVerifier.sol:AgentIdVerifier --chain 56 --verifier sourcify \
  --constructor-args $(cast abi-encode "f(address)" 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F)
forge verify-contract <token> src/FairToken.sol:FairToken --chain 56 --verifier sourcify --guess-constructor-args \
  --rpc-url https://bsc-dataseed.bnbchain.org \
  --libraries src/FairTokenParams.sol:FairTokenParams:0x2DeF7c6f02BA9166BA74dA6853afCEbC58E8a12c
forge verify-contract <extension> src/FairTokenExt.sol:FairTokenExt --chain 56 --verifier sourcify \
  --libraries src/FairTokenParams.sol:FairTokenParams:0x2DeF7c6f02BA9166BA74dA6853afCEbC58E8a12c
```

`FairTokenExt` has the same constructor arguments as `FairToken` (the same `Params`). For BscScan, use the same commands with `--verifier etherscan --etherscan-api-key <your key>`. Use the key only on the command line or in a local environment; never commit it.

Then go through the 8 checks in the README section "Checking for backdoors on BscScan".

## 6. Switch the website to mainnet

The website source is not part of this repository.

1. Fill in `tokenAddress` and `verifier` in `web/public/config.mainnet.json`.
2. `cd web && npm run site:mainnet`. The script checks chain ID 56 and the router / factory / WBNB / registry / project wallet addresses, and refuses empty or testnet addresses. The build has no TESTNET banner.
3. Publish to a preview domain first, then to the production domain once confirmed. Publishing is a separate `surge` command; the build script does not upload.

## Do not do now

- Do not put private keys in `.env`, command-line arguments or the repository.
- Do not remove the private-key environment variable check from the script.
- Do not broadcast before steps 1–2 have all passed.
