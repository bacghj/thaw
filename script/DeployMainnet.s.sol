// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {FairToken} from "../src/FairToken.sol";
import {AgentIdVerifier} from "../src/verifiers/AgentIdVerifier.sol";
import {IPancakeRouter} from "../src/interfaces/IPancakeV2.sol";

/// @notice Approved HIVEN mainnet parameters. Every value is a constant: there is no env override.
///         Changing a launch parameter means editing this file, reviewing the diff, and re-running
///         the fork checks in `test/DeployMainnet.t.sol`.
abstract contract HivenMainnetConfig {
    uint256 internal constant CHAIN_ID = 56;

    address internal constant PANCAKE_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address internal constant PANCAKE_FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    /// SPACE ID Agent ID registry (soulbound ERC-721, "SPACE ID Agent ID" / "AI").
    address internal constant AGENT_REGISTRY = 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F;

    /// The only address allowed to send the deploy transactions. It gets no role in the contracts.
    address internal constant DEPLOYER = 0x57287D08B85793A3d0be9908d2696Fab37371Eb8;
    /// Immutable receiver of the 10% mint fee and the 1.5% dev tax. Must accept plain BNB.
    address internal constant DEV_WALLET = 0xb96401CD93006eb68A86Ee2006fd3f4B85e32045;

    string internal constant NAME = "HIVEN";
    string internal constant SYMBOL = "HIVEN";

    uint256 internal constant HARD_CAP = 30_000;
    uint256 internal constant SOFT_CAP = 2_000;
    uint256 internal constant TIER1_PRICE = 0.004 ether;
    uint256 internal constant TIER2_PRICE = 0.005 ether;
    uint256 internal constant TIER3_PRICE = 0.006 ether;
    uint16 internal constant TIER1_BPS = 2500;
    uint16 internal constant TIER2_BPS = 5000;
    uint256 internal constant TIER1_END = 7_500;
    uint256 internal constant TIER2_END = 22_500;
    uint256 internal constant MAX_PER_WALLET = 5;
    uint256 internal constant MAX_PER_IDENTITY = 5;
    uint256 internal constant MINT_DURATION = 72 hours; // 259200
    uint256 internal constant TOKENS_PER_SHARE = 3000 ether;
    uint256 internal constant PREMIUM_NUM = 3;
    uint256 internal constant PREMIUM_DEN = 2;
    uint16 internal constant IMMEDIATE_BPS = 1500;
    uint256 internal constant DEMAND_NUM = 50;
    uint256 internal constant DEMAND_DEN = 100;
    uint256 internal constant VEST_CLIFF = 7 days; // 604800
    uint256 internal constant VEST_LINEAR = 7 days; // 604800
    uint256 internal constant FORFEIT_FULL_RATE = 3 days; // 259200
    uint256 internal constant FORFEIT_WINDOW = 14 days; // 1209600
    uint256 internal constant SWAP_THRESHOLD = 3000 ether;
    uint256 internal constant MIN_UNIT = 1e12;
    uint16 internal constant MINT_FEE_BPS = 1000;
    uint256 internal constant TWAP_WINDOW = 30 minutes;
    uint16 internal constant TWAP_MAX_DEVIATION_BPS = 1000;

    error WrongChain(uint256 chainId);
    error PrivateKeyEnvForbidden(string name);
    error Check(string what);

    function approvedParams(address verifier) internal pure returns (FairToken.Params memory p) {
        p.name = NAME;
        p.symbol = SYMBOL;
        p.verifier = verifier;
        p.devWallet = DEV_WALLET;
        p.router = PANCAKE_ROUTER;
        p.factory = PANCAKE_FACTORY;
        p.wbnb = WBNB;
        p.hardCap = HARD_CAP;
        p.softCap = SOFT_CAP;
        p.tier1Price = TIER1_PRICE;
        p.tier2Price = TIER2_PRICE;
        p.tier3Price = TIER3_PRICE;
        p.tier1Bps = TIER1_BPS;
        p.tier2Bps = TIER2_BPS;
        p.maxPerWallet = MAX_PER_WALLET;
        p.maxPerIdentity = MAX_PER_IDENTITY;
        p.mintDuration = MINT_DURATION;
        p.tokensPerShare = TOKENS_PER_SHARE;
        p.premiumNum = PREMIUM_NUM;
        p.premiumDen = PREMIUM_DEN;
        p.immediateUnlockBps = IMMEDIATE_BPS;
        p.demandNum = DEMAND_NUM;
        p.demandDen = DEMAND_DEN;
        p.vestCliff = VEST_CLIFF;
        p.vestLinear = VEST_LINEAR;
        p.forfeitFullRate = FORFEIT_FULL_RATE;
        p.forfeitWindow = FORFEIT_WINDOW;
        p.swapThreshold = SWAP_THRESHOLD;
        p.minUnit = MIN_UNIT;
        p.mintFeeBps = MINT_FEE_BPS;
        p.twapWindow = TWAP_WINDOW;
        p.twapMaxDeviationBps = TWAP_MAX_DEVIATION_BPS;
    }

    function _req(bool ok, string memory what) internal pure {
        if (!ok) revert Check(what);
    }

    /// @notice Economic sanity on the approved numbers, beyond what `FairTokenParams` enforces.
    function checkInvariants(FairToken.Params memory p) internal pure {
        _req(p.tier1Price < p.tier2Price && p.tier2Price < p.tier3Price, "tiers ascending");
        // Requested bound: tier3 <= premium x tier1. With 0.006 = 1.5 x 0.004 this holds with equality,
        // i.e. a tier-3 share would be exactly at cost only if the average were the tier-1 price,
        // which cannot happen once tier 3 is reached. The strict checks below use the real worst case.
        _req(p.tier3Price * p.premiumDen <= p.tier1Price * p.premiumNum, "tier3 <= premium x tier1");
        // Worst case for a tier-2 buyer: the first tier-2 share, average ~= tier-1 price.
        _req(
            p.tier2Price * p.premiumDen * TIER1_END < p.premiumNum * p.tier1Price * TIER1_END, "tier2 in profit at open"
        );
        // Worst case for a tier-3 buyer: the first tier-3 share, average = cost of tiers 1+2.
        uint256 costT2 = p.tier1Price * TIER1_END + p.tier2Price * (TIER2_END - TIER1_END);
        _req(p.tier3Price * p.premiumDen * TIER2_END < p.premiumNum * costT2, "tier3 in profit at open");
        _req(p.premiumNum * 2 == p.premiumDen * 3, "premium 1.5x");
        _req(p.softCap > 0 && p.softCap <= TIER1_END, "softCap inside tier 1");
        _req(p.hardCap * p.tier1Bps / 10_000 == TIER1_END, "tier1 end");
        _req(p.hardCap * p.tier1Bps / 10_000 + p.hardCap * p.tier2Bps / 10_000 == TIER2_END, "tier2 end");
        _req(p.maxPerWallet == p.maxPerIdentity, "wallet cap == id cap");
        _req(p.mintFeeBps == 1000, "10% fee");
        _req(p.twapWindow >= 15 minutes && p.twapWindow <= 2 hours, "twap window range");
        _req(p.twapMaxDeviationBps > 0 && p.twapMaxDeviationBps <= 2000, "deviation guard on, <=20%");
        _req(p.forfeitWindow == p.vestCliff + p.vestLinear, "forfeit ends when vest ends");
        _req(p.forfeitFullRate < p.vestCliff, "full forfeit inside cliff");
        _req(p.mintDuration == 72 hours && p.mintDuration == 259200, "72h window");
        _req(p.immediateUnlockBps == 1500, "15% at open");
    }

    /// @notice Field-by-field equality with the approved constants. Guards against an edited builder.
    function checkApproved(FairToken.Params memory p, address verifier) internal pure {
        FairToken.Params memory a = approvedParams(verifier);
        _req(keccak256(abi.encode(p)) == keccak256(abi.encode(a)), "params == approved");
    }

    /// @notice Read every immutable back from a deployed token and compare to the approved values.
    function checkDeployed(FairToken t, AgentIdVerifier v, uint256 deployTs) internal view {
        _req(address(t).code.length > 0, "token code");
        _req(t.extension().code.length > 0, "extension code");
        _req(keccak256(bytes(t.name())) == keccak256(bytes(NAME)), "name");
        _req(keccak256(bytes(t.symbol())) == keccak256(bytes(SYMBOL)), "symbol");
        _req(t.decimals() == 18, "decimals");
        _req(address(t.verifier()) == address(v), "verifier");
        _req(v.registry() == AGENT_REGISTRY, "registry");
        _req(t.devWallet() == DEV_WALLET, "devWallet");
        _req(t.router() == PANCAKE_ROUTER, "router");
        _req(t.factory() == PANCAKE_FACTORY, "factory");
        _req(t.wbnb() == WBNB, "wbnb");
        _req(t.hardCap() == HARD_CAP, "hardCap");
        _req(t.softCap() == SOFT_CAP, "softCap");
        _req(t.tier1Price() == TIER1_PRICE, "tier1Price");
        _req(t.tier2Price() == TIER2_PRICE, "tier2Price");
        _req(t.tier3Price() == TIER3_PRICE, "tier3Price");
        _req(t.tier1End() == TIER1_END, "tier1End");
        _req(t.tier2End() == TIER2_END, "tier2End");
        _req(t.maxPerWallet() == MAX_PER_WALLET, "maxPerWallet");
        _req(t.maxPerIdentity() == MAX_PER_IDENTITY, "maxPerIdentity");
        _req(t.deadline() == deployTs + MINT_DURATION, "deadline");
        _req(t.tokensPerShare() == TOKENS_PER_SHARE, "tokensPerShare");
        _req(t.immediatePerShare() == TOKENS_PER_SHARE * IMMEDIATE_BPS / 10_000, "immediatePerShare");
        _req(t.lockedPerShare() == TOKENS_PER_SHARE - TOKENS_PER_SHARE * IMMEDIATE_BPS / 10_000, "lockedPerShare");
        _req(t.premiumNum() == PREMIUM_NUM && t.premiumDen() == PREMIUM_DEN, "premium");
        _req(t.demandNum() == DEMAND_NUM && t.demandDen() == DEMAND_DEN, "demand");
        _req(t.vestCliff() == VEST_CLIFF && t.vestLinear() == VEST_LINEAR, "vest");
        _req(t.forfeitFullRate() == FORFEIT_FULL_RATE && t.forfeitWindow() == FORFEIT_WINDOW, "forfeit");
        _req(t.swapThreshold() == SWAP_THRESHOLD, "swapThreshold");
        _req(t.minUnit() == MIN_UNIT, "minUnit");
        _req(t.mintFeeBps() == MINT_FEE_BPS, "mintFeeBps");
        _req(t.twapWindow() == TWAP_WINDOW, "twapWindow");
        _req(t.twapMaxDeviationBps() == TWAP_MAX_DEVIATION_BPS, "twapMaxDeviationBps");
        _req(t.TAX_BPS() == 300 && t.DEV_BPS() == 150 && t.LP_BPS() == 150, "tax constants");
        _req(t.DEAD() == 0x000000000000000000000000000000000000dEaD, "dead");
        // Fresh state.
        _req(t.totalSupply() == 0 && t.sold() == 0 && t.raised() == 0, "fresh supply");
        _req(!t.launched() && !t.refundMode() && t.pair() == address(0), "fresh launch state");
        _req(t.currentPhase() == 0, "phase mint");
        _req(address(t).balance == 0, "no BNB");
        // No admin surface: none of these selectors may exist.
        string[9] memory admin = [
            "owner()",
            "getOwner()",
            "admin()",
            "pause()",
            "paused()",
            "renounceOwnership()",
            "transferOwnership(address)",
            "setDevWallet(address)",
            "upgradeTo(address)"
        ];
        for (uint256 i; i < admin.length; ++i) {
            bytes memory data = abi.encodeWithSignature(admin[i], address(0));
            (bool ok,) = address(t).staticcall(data);
            _req(!ok, string.concat("admin selector present: ", admin[i]));
        }
    }

    /// @notice Live-chain preconditions read before deploying.
    function checkChain() internal view {
        if (block.chainid != CHAIN_ID) revert WrongChain(block.chainid);
        _req(IPancakeRouter(PANCAKE_ROUTER).factory() == PANCAKE_FACTORY, "router.factory");
        _req(IPancakeRouter(PANCAKE_ROUTER).WETH() == WBNB, "router.WETH");
        _req(AGENT_REGISTRY.code.length > 0, "registry code");
        // devWallet must accept plain BNB or finalize reverts. Today it is an EOA (no code).
        // A 23-byte EIP-7702 designator is tolerated; any other contract code is refused.
        uint256 len = DEV_WALLET.code.length;
        _req(len == 0 || len == 23, "devWallet must be EOA");
    }
}

/// @notice HIVEN BSC mainnet deployment. Chain 56 only. No key is read from the environment.
///         The signer must come from the CLI as a hardware wallet (`--ledger` / `--trezor`)
///         or an encrypted keystore (`--account <name>`), with `--sender 0x5728…1Eb8`.
///         Dry run (default, no `--broadcast`) only simulates.
contract DeployMainnet is Script, HivenMainnetConfig {
    function run() external returns (FairToken token, AgentIdVerifier verifier) {
        checkChain();
        _refuseKeyEnv();
        checkInvariants(approvedParams(address(1)));

        console2.log("deployer", DEPLOYER);
        console2.log("deployer balance (wei)", DEPLOYER.balance);

        uint256 deployTs = vm.getBlockTimestamp();
        vm.startBroadcast(DEPLOYER);
        verifier = new AgentIdVerifier(AGENT_REGISTRY);
        FairToken.Params memory p = approvedParams(address(verifier));
        checkApproved(p, address(verifier));
        checkInvariants(p);
        token = new FairToken(p);
        vm.stopBroadcast();

        checkDeployed(token, verifier, deployTs);

        console2.log("chain", block.chainid);
        console2.log("verifier", address(verifier));
        console2.log("token", address(token));
        console2.log("extension", token.extension());
        console2.log("deadline (unix)", token.deadline());
        console2.log("all post-deploy checks passed");
    }

    function _refuseKeyEnv() internal view {
        string[4] memory names = ["DEPLOYER_KEY", "PRIVATE_KEY", "ETH_PRIVATE_KEY", "MAINNET_KEY"];
        for (uint256 i; i < names.length; ++i) {
            if (bytes(vm.envOr(names[i], string(""))).length != 0) revert PrivateKeyEnvForbidden(names[i]);
        }
    }
}

/// @notice Read-only post-deploy check against the live chain. Run right after deployment, before the
///         first mint (it also asserts fresh state): every immutable equals the approved value, no admin
///         entry points, LP/pair not yet created.
///         `forge script script/DeployMainnet.s.sol:CheckMainnetDeployment --sig "run(address)" <token> --rpc-url bsc`
contract CheckMainnetDeployment is Script, HivenMainnetConfig {
    function run(address token) external view {
        checkChain();
        FairToken t = FairToken(payable(token));
        uint256 deployTs = t.deadline() - MINT_DURATION;
        checkDeployed(t, AgentIdVerifier(address(t.verifier())), deployTs);
        console2.log("token", token);
        console2.log("verifier", address(t.verifier()));
        console2.log("extension", t.extension());
        console2.log("deadline (unix)", t.deadline());
        console2.log("on-chain readback matches approved params");
    }
}
