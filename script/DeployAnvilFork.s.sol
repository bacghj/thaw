// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {FairToken} from "../src/FairToken.sol";
import {MockAgentIdVerifier} from "../test/mocks/MockAgentIdVerifier.sol";

/// @notice Deploy onto a local anvil fork of BSC only.
///         Refuses any node that does not implement `anvil_nodeInfo`, so this cannot broadcast to BSC mainnet.
contract DeployAnvilFork is Script {
    address constant PANCAKE_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant PANCAKE_FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    address constant ANVIL_1 = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address constant ANVIL_2 = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;

    error NotAnvil();

    function run() external returns (FairToken token, MockAgentIdVerifier verifier) {
        try vm.rpc("anvil_nodeInfo", "[]") returns (bytes memory) {}
        catch {
            revert NotAnvil();
        }

        uint256 key = vm.envUint("ANVIL_KEY");
        bool small = keccak256(bytes(vm.envOr("LOCAL_KIND", string("product")))) == keccak256("small");

        vm.startBroadcast(key);
        verifier = new MockAgentIdVerifier();
        address miner = vm.addr(key);
        verifier.set(miner, bytes32("local-a"));
        verifier.set(ANVIL_2, bytes32("local-c"));
        // ANVIL_1 is left without an Agent ID on purpose.

        FairToken.Params memory p;
        p.name = "HIVEN";
        p.symbol = "HIVEN";
        p.verifier = address(verifier);
        p.devWallet = ANVIL_1;
        p.router = PANCAKE_ROUTER;
        p.factory = PANCAKE_FACTORY;
        p.wbnb = WBNB;
        p.tier1Price = 0.004 ether;
        p.tier2Price = 0.005 ether;
        p.tier3Price = 0.006 ether;
        p.tier1Bps = 2500;
        p.tier2Bps = 5000;
        p.mintDuration = 48 hours;
        p.tokensPerShare = 3000 ether;
        p.premiumNum = 3;
        p.premiumDen = 2;
        p.immediateUnlockBps = 3000;
        p.demandNum = 50;
        p.demandDen = 100;
        p.vestCliff = 7 days;
        p.vestLinear = 7 days;
        p.forfeitFullRate = 3 days;
        p.forfeitWindow = 14 days;
        p.swapThreshold = 1;
        p.minUnit = 1e12;
        if (small) {
            p.hardCap = 8;
            p.softCap = 4;
            p.maxPerWallet = 5;
            p.maxPerIdentity = 5;
        } else {
            p.hardCap = 30_000;
            p.softCap = 1_000;
            p.maxPerWallet = 5;
            p.maxPerIdentity = 5;
        }
        token = new FairToken(p);
        vm.stopBroadcast();

        console2.log("kind", small ? "small" : "product");
        console2.log("verifier", address(verifier));
        console2.log("token", address(token));
        console2.log("miner", miner);
    }
}
