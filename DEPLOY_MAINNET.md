# HIVEN 主网部署步骤（BSC，链 56）

脚本：`script/DeployMainnet.s.sol`。合约源码（`src/`）不改。仓库里不放私钥，`.env` 也不放。脚本发现 `DEPLOYER_KEY` / `PRIVATE_KEY` / `ETH_PRIVATE_KEY` / `MAINNET_KEY` 任一非空会直接回退。签名只用硬件钱包（`--ledger` / `--trezor`）或加密 keystore（`--account`）。

## 脚本锁定的参数

| 参数 | 值 |
|---|---|
| 硬顶 / 软顶 | 30,000 / 2,000 份 |
| 每份代币 | 3,000 HIVEN |
| 价格档 | 1–7,500：0.004 BNB；7,501–22,500：0.005 BNB；22,501–30,000：0.006 BNB |
| 每钱包（认购期）/ 每 Agent ID（终身） | 5 / 5 份 |
| 认购窗口 | 48 小时（`deadline = 部署区块时间 + 172800`） |
| 开池价 | 平均成本 × 3/2 |
| 铸造 BNB 分配 | 10% 项目钱包 / 90% 流动池 |
| 解锁 | 开池 15%；需求解锁 1:2；cliff 604800 秒 + 线性 604800 秒 |
| 罚没 | 前 259200 秒 100%，到 1209600 秒线性降到 0 |
| 开池后铸造 | TWAP 窗口 1800 秒，偏离上限 10% |
| 换币阈值 / 最小单位 | 3,000 HIVEN / 1e12 |
| 路由 / 工厂 / WBNB | `0x10ED…024E` / `0xcA14…0c73` / `0xbb4C…095c` |
| Agent ID 注册表 | `0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F` |
| 项目钱包（不可改） | `0xb96401CD93006eb68A86Ee2006fd3f4B85e32045` |
| 部署者（`--sender`） | `0x57287D08B85793A3d0be9908d2696Fab37371Eb8` |

参数只要有一项和上表不同，脚本就回退。要改参数只能改脚本常量，然后从第 1 步重来。签名地址必须是上面的部署者。如果换硬件钱包地址，要改脚本里的 `DEPLOYER` 并重跑第 1–2 步。

注：第 3 档价格正好等于第 1 档的 1.5 倍（0.006 = 1.5 × 0.004），不是严格小于。脚本另外严格检查：只要第 2 档或第 3 档有成交，全体平均成本 × 1.5 一定高于该档单价。

## 1. 测试（不上链）

```bash
forge build
forge test --no-match-contract "ForkTest"
BSC_RPC_URL=https://bsc-rpc.publicnode.com forge test --match-contract "ForkTest"
```

`DeployMainnetForkTest` 在主网分叉上跑部署脚本，覆盖以下几项：
- 参数回读；
- 无 owner / 无管理函数；
- 软顶开池，10% 到项目钱包，90% 进池；
- LP 除 Pancake 的 1000 wei 外全部在 `0x…dEaD`；
- 开池价 1.5 倍；
- TWAP 铸造与多付退款；
- 不足软顶全额退款；
- 6,000 个 ID 铸满硬顶后开池（实测 finalize 约 3.94M gas，含 createPair）。

## 2. 模拟部署（不加 `--broadcast`）

```bash
forge script script/DeployMainnet.s.sol:DeployMainnet \
  --rpc-url https://bsc-dataseed.bnbchain.org \
  --sender 0x57287D08B85793A3d0be9908d2696Fab37371Eb8
```

日志最后一行应为 `all post-deploy checks passed`。会有 3 笔交易：
1. CREATE2 部署 `FairTokenParams` 库，地址 `0x2DeF7c6f02BA9166BA74dA6853afCEbC58E8a12c`；
2. `AgentIdVerifier`；
3. `FairToken`。

预计约 13.2M gas，按 0.05 gwei 约 0.00066 BNB。实际按当时 gas 价计算，部署者至少留 0.003 BNB。

## 3. 广播（由持有硬件钱包的人在自己电脑上执行）

```bash
# Ledger：解锁并打开 Ethereum 应用，开启 blind signing（合约部署需要）
forge script script/DeployMainnet.s.sol:DeployMainnet \
  --rpc-url https://bsc-dataseed.bnbchain.org \
  --ledger --sender 0x57287D08B85793A3d0be9908d2696Fab37371Eb8 \
  --broadcast --slow
```

如果用 Trezor，把 `--ledger` 换成 `--trezor`。如果用加密 keystore，换成 `--account <名字>`（先用 `cast wallet import <名字> --interactive` 导入，私钥只在本机加密保存）。

每笔交易都要在设备上确认。`--slow` 让交易一笔确认后再发下一笔。输出里记下 `verifier`、`token`、`extension` 的地址。

## 4. 上链回读（只读）

在第一笔铸造之前立即执行：

```bash
forge script script/DeployMainnet.s.sol:CheckMainnetDeployment \
  --sig "run(address)" <token 地址> --rpc-url https://bsc-dataseed.bnbchain.org
```

应输出 `on-chain readback matches approved params`。再在 BscScan 上看 `deadline()`，应等于部署交易的区块时间 + 172800。

## 5. 源码验证

```bash
# Sourcify（不需要 API key）
forge verify-contract <库地址 0x2DeF…> src/FairTokenParams.sol:FairTokenParams --chain 56 --verifier sourcify
forge verify-contract <verifier> src/verifiers/AgentIdVerifier.sol:AgentIdVerifier --chain 56 --verifier sourcify \
  --constructor-args $(cast abi-encode "f(address)" 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F)
forge verify-contract <token> src/FairToken.sol:FairToken --chain 56 --verifier sourcify --guess-constructor-args \
  --rpc-url https://bsc-dataseed.bnbchain.org \
  --libraries src/FairTokenParams.sol:FairTokenParams:0x2DeF7c6f02BA9166BA74dA6853afCEbC58E8a12c
forge verify-contract <extension> src/FairTokenExt.sol:FairTokenExt --chain 56 --verifier sourcify \
  --libraries src/FairTokenParams.sol:FairTokenParams:0x2DeF7c6f02BA9166BA74dA6853afCEbC58E8a12c
```

`FairTokenExt` 的构造参数和 `FairToken` 相同（同一个 `Params`）。BscScan 用同样的命令，改成 `--verifier etherscan --etherscan-api-key <你的 key>`。key 只在命令行或本机环境里用，不提交。

然后按 README「在 BscScan 上确认没有后门」的 8 条逐项核对。

## 现在不要做

- 不要把私钥放进 `.env`、命令行参数或仓库。
- 不要删脚本里的私钥环境变量检查。
- 不要在第 1–2 步全部通过之前广播。
