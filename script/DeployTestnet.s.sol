// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {FairToken} from "../src/FairToken.sol";
import {AgentIdVerifier} from "../src/verifiers/AgentIdVerifier.sol";
import {MockHandleRegistry} from "../src/testnet/MockHandleRegistry.sol";

/// @notice BSC testnet (chain 97) only. Refuses every other chain, including mainnet.
///         The key is read from DEPLOYER_KEY. This file does not contain a key.
///
///         Durations, prices, and caps are constructor arguments of `FairToken`.
///         The testnet run passes minute-scale values. Production bytecode is unchanged.
contract DeployTestnet is Script {
    address constant TESTNET_ROUTER = 0xD99D1c33F9fC3444f8101754aBC46c52416550D1;
    address constant TESTNET_FACTORY = 0x6725F303b657a9451d8BA641348b6761A6CC7a17;
    address constant TESTNET_WBNB = 0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd;
    address constant TEST_DEV = 0xb96401CD93006eb68A86Ee2006fd3f4B85e32045;

    error WrongChain(uint256 id);

    function run() external {
        if (block.chainid != 97) revert WrongChain(block.chainid);

        uint256 key = vm.envUint("DEPLOYER_KEY");
        vm.startBroadcast(key);

        address registry = vm.envOr("MOCK_REGISTRY", address(0));
        if (registry == address(0)) {
            registry = address(new MockHandleRegistry());
        }
        _register(registry, vm.envOr("AGENT_A", address(0)), vm.envOr("HANDLE_A", string("")));
        _register(registry, vm.envOr("AGENT_B", address(0)), vm.envOr("HANDLE_B", string("")));
        _register(registry, vm.envOr("AGENT_C", address(0)), vm.envOr("HANDLE_C", string("")));

        address verifier = vm.envOr("VERIFIER", address(0));
        if (verifier == address(0)) {
            verifier = address(new AgentIdVerifier(registry));
        }

        address token;
        if (vm.envOr("DEPLOY_TOKEN", uint256(0)) == 1) {
            FairToken deployed = new FairToken(_params(verifier));
            token = address(deployed);
            uint256 shares = vm.envOr("MINT_SHARES", uint256(0));
            if (shares > 0) {
                (uint256 cost,) = deployed.quote(shares);
                deployed.mint{value: cost}(shares);
            }
        }

        vm.stopBroadcast();

        console2.log("chain", block.chainid);
        console2.log("registry", registry);
        console2.log("verifier", verifier);
        console2.log("token", token);
    }

    function _register(address registry, address account, string memory handle) internal {
        if (account == address(0)) return;
        MockHandleRegistry(registry).register(account, handle);
    }

    function _params(address verifier) internal view returns (FairToken.Params memory p) {
        p.name = vm.envOr("TOKEN_NAME", string("THAW"));
        p.symbol = vm.envOr("TOKEN_SYMBOL", string("THAW"));
        p.verifier = verifier;
        p.devWallet = vm.envOr("DEV_WALLET", TEST_DEV);
        p.router = vm.envOr("ROUTER", TESTNET_ROUTER);
        p.factory = vm.envOr("FACTORY", TESTNET_FACTORY);
        p.wbnb = vm.envOr("WBNB", TESTNET_WBNB);
        p.hardCap = vm.envOr("HARD_CAP", uint256(8));
        p.softCap = vm.envOr("SOFT_CAP", uint256(4));
        p.tier1Price = vm.envOr("TIER1_PRICE", uint256(0.0001 ether));
        p.tier2Price = vm.envOr("TIER2_PRICE", uint256(0.00012 ether));
        p.tier3Price = vm.envOr("TIER3_PRICE", uint256(0.00015 ether));
        p.tier1Bps = uint16(vm.envOr("TIER1_BPS", uint256(2500)));
        p.tier2Bps = uint16(vm.envOr("TIER2_BPS", uint256(5000)));
        p.maxPerWallet = vm.envOr("MAX_PER_WALLET", uint256(5));
        p.maxPerIdentity = vm.envOr("MAX_PER_IDENTITY", uint256(5));
        p.mintDuration = vm.envOr("MINT_DURATION", uint256(5 minutes));
        p.tokensPerShare = vm.envOr("TOKENS_PER_SHARE", uint256(3000 ether));
        p.premiumNum = vm.envOr("PREMIUM_NUM", uint256(3));
        p.premiumDen = vm.envOr("PREMIUM_DEN", uint256(2));
        p.immediateUnlockBps = uint16(vm.envOr("IMMEDIATE_BPS", uint256(1500)));
        p.mintFeeBps = uint16(vm.envOr("MINT_FEE_BPS", uint256(1000)));
        p.twapWindow = vm.envOr("TWAP_WINDOW", uint256(30 minutes));
        p.twapMaxDeviationBps = uint16(vm.envOr("TWAP_MAX_DEVIATION_BPS", uint256(1000)));
        p.demandNum = vm.envOr("DEMAND_NUM", uint256(50));
        p.demandDen = vm.envOr("DEMAND_DEN", uint256(100));
        p.vestCliff = vm.envOr("VEST_CLIFF", uint256(2 minutes));
        p.vestLinear = vm.envOr("VEST_LINEAR", uint256(3 minutes));
        p.forfeitFullRate = vm.envOr("FORFEIT_FULL_RATE", uint256(5 minutes));
        p.forfeitWindow = vm.envOr("FORFEIT_WINDOW", uint256(10 minutes));
        p.swapThreshold = vm.envOr("SWAP_THRESHOLD", uint256(1 ether));
        p.minUnit = vm.envOr("MIN_UNIT", uint256(1e12));
    }
}
