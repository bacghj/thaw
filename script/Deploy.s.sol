// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {FairToken} from "../src/FairToken.sol";
import {AgentIdVerifier} from "../src/verifiers/AgentIdVerifier.sol";

/// @notice Deploy FairToken from environment variables.
///         Broadcasting to BSC mainnet (chain id 56) is refused, even if a key is present.
///         Fork simulation (chain id 56, no key, no --broadcast) is allowed.
///
///         Never put a real key in the shell history you care about. Prefer a throwaway
///         testnet key. This script does not embed a key.
contract Deploy is Script {
    address constant PANCAKE_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant PANCAKE_FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant AGENT_REGISTRY = 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F;

    error MainnetBroadcastForbidden();
    error MissingConfig();

    function run() external returns (FairToken token, AgentIdVerifier adapter) {
        uint256 key = vm.envOr("DEPLOYER_KEY", uint256(0));
        if (key != 0 && block.chainid == 56) revert MainnetBroadcastForbidden();

        FairToken.Params memory p = _params();
        if (key != 0) vm.startBroadcast(key);
        address registry = vm.envOr("AGENT_REGISTRY", block.chainid == 56 ? AGENT_REGISTRY : address(0));
        if (registry == address(0)) revert MissingConfig();
        adapter = new AgentIdVerifier(registry);
        p.verifier = address(adapter);
        token = new FairToken(p);
        if (key != 0) vm.stopBroadcast();

        console2.log("verifier", address(adapter));
        console2.log("token", address(token));
        console2.log("pair-will-be-created-on-finalize");
        console2.log("chain", block.chainid);
    }

    function _params() internal view returns (FairToken.Params memory p) {
        p.name = vm.envOr("TOKEN_NAME", string("HIVEN"));
        p.symbol = vm.envOr("TOKEN_SYMBOL", string("HIVEN"));
        p.devWallet = vm.envOr("DEV_WALLET", address(0));
        if (p.devWallet == address(0)) revert MissingConfig();
        p.router = vm.envOr("ROUTER", block.chainid == 56 ? PANCAKE_ROUTER : address(0));
        p.factory = vm.envOr("FACTORY", block.chainid == 56 ? PANCAKE_FACTORY : address(0));
        p.wbnb = vm.envOr("WBNB", block.chainid == 56 ? WBNB : address(0));
        if (p.router == address(0) || p.factory == address(0) || p.wbnb == address(0)) revert MissingConfig();

        p.hardCap = vm.envOr("HARD_CAP", uint256(30_000));
        p.softCap = vm.envOr("SOFT_CAP", uint256(1_000));
        p.tier1Price = vm.envOr("TIER1_PRICE", uint256(0.004 ether));
        p.tier2Price = vm.envOr("TIER2_PRICE", uint256(0.005 ether));
        p.tier3Price = vm.envOr("TIER3_PRICE", uint256(0.006 ether));
        p.tier1Bps = uint16(vm.envOr("TIER1_BPS", uint256(2500)));
        p.tier2Bps = uint16(vm.envOr("TIER2_BPS", uint256(5000)));
        p.maxPerWallet = vm.envOr("MAX_PER_WALLET", uint256(5));
        p.maxPerIdentity = vm.envOr("MAX_PER_IDENTITY", uint256(5));
        p.mintDuration = vm.envOr("MINT_DURATION", uint256(48 hours));
        p.tokensPerShare = vm.envOr("TOKENS_PER_SHARE", uint256(3000 ether));
        p.premiumNum = vm.envOr("PREMIUM_NUM", uint256(3));
        p.premiumDen = vm.envOr("PREMIUM_DEN", uint256(2));
        p.immediateUnlockBps = uint16(vm.envOr("IMMEDIATE_BPS", uint256(3000)));
        p.demandNum = vm.envOr("DEMAND_NUM", uint256(50));
        p.demandDen = vm.envOr("DEMAND_DEN", uint256(100));
        p.vestCliff = vm.envOr("VEST_CLIFF", uint256(7 days));
        p.vestLinear = vm.envOr("VEST_LINEAR", uint256(7 days));
        p.forfeitFullRate = vm.envOr("FORFEIT_FULL_RATE", uint256(3 days));
        p.forfeitWindow = vm.envOr("FORFEIT_WINDOW", uint256(14 days));
        p.swapThreshold = vm.envOr("SWAP_THRESHOLD", uint256(3000 ether));
        p.minUnit = vm.envOr("MIN_UNIT", uint256(1e12));
    }
}
