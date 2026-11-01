// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {FairToken} from "../src/FairToken.sol";
import {MockAgentIdVerifier} from "./mocks/MockAgentIdVerifier.sol";
import {MiniFactory, MiniPair, MiniRouter, MiniWBNB} from "./mocks/MiniAmm.sol";
import {EntitlementOracle} from "./EntitlementOracle.sol";

/// @notice Stateful fuzz across the 14-day window. Each step checks that every
///         holder is paid their own entitlement, in both directions.
contract EntitlementFuzzTest is Test {
    uint256 private constant STEPS = 200;

    function testFuzz_smallSupplyEntitlement(uint256 seed) public {
        _run(seed, true);
    }

    function testFuzz_defaultParamsEntitlement(uint256 seed) public {
        _run(seed, false);
    }

    function _run(uint256 seed, bool small) internal {
        MockAgentIdVerifier ver = new MockAgentIdVerifier();
        MiniWBNB wbnb = new MiniWBNB();
        MiniFactory factory = new MiniFactory();
        MiniRouter router = new MiniRouter(address(factory), address(wbnb));

        uint256 holdersN = small ? 8 : 16;
        FairToken.Params memory p;
        p.name = small ? "Small" : "Fair Mint Token";
        p.symbol = small ? "S" : "FMT";
        p.verifier = address(ver);
        p.devWallet = makeAddr("dev");
        p.router = address(router);
        p.factory = address(factory);
        p.wbnb = address(wbnb);
        p.hardCap = holdersN;
        p.softCap = 4;
        p.tier1Price = 0.004 ether;
        p.tier2Price = 0.005 ether;
        p.tier3Price = 0.006 ether;
        p.tier1Bps = 2500;
        p.tier2Bps = 5000;
        p.maxPerWallet = 2;
        p.maxPerIdentity = 2;
        p.mintDuration = 2 days;
        p.tokensPerShare = small ? 30_000 : 3000 ether;
        p.premiumNum = 3;
        p.premiumDen = 2;
        p.immediateUnlockBps = 3000;
        p.demandNum = 50;
        p.demandDen = 100;
        p.vestCliff = 7 days;
        p.vestLinear = 7 days;
        p.forfeitFullRate = 3 days;
        p.forfeitWindow = 14 days;
        p.swapThreshold = 1_000_000 ether;
        p.minUnit = small ? 1 : 1e12;
        FairToken token = new FairToken(p);

        address[] memory holders = new address[](holdersN);
        for (uint256 i; i < holdersN; ++i) {
            holders[i] = makeAddr(string(abi.encodePacked(small ? "s" : "d", i)));
            ver.set(holders[i], bytes32(i + 1));
            vm.deal(holders[i], 100 ether);
            (uint256 cost,) = token.quote(1);
            vm.prank(holders[i]);
            token.mint{value: cost}(1);
        }
        token.finalize();
        EntitlementOracle oracle = new EntitlementOracle(token, holders);
        address sink = makeAddr("sink");
        vm.deal(address(this), 50 ether);

        for (uint256 step; step < STEPS; ++step) {
            uint256 roll = uint256(keccak256(abi.encode(seed, step)));
            uint256 kind = roll % 7;
            if (kind == 0) {
                token.poke();
            } else if (kind == 1) {
                address a = holders[roll % holdersN];
                vm.prank(a);
                try token.claim() {} catch {}
            } else if (kind == 2) {
                uint256 dt = 1 hours + (roll % 2 days);
                vm.warp(block.timestamp + dt);
                vm.roll(block.number + 1);
                if (block.timestamp >= token.openTime() + token.forfeitWindow()) token.poke();
            } else if (kind == 3) {
                _transfer(token, holders, sink, roll);
            } else if (kind == 4) {
                if (small) _tinyBuy(token, wbnb, 1 + (roll % 30));
                else _buy(token, router, holders[roll % holdersN], 0.001 ether + (roll % 0.004 ether));
            } else if (kind == 5) {
                _sell(token, router, holders[roll % holdersN], 1 + (roll % 50));
            } else {
                vm.roll(block.number + 1);
                token.poke();
            }
            oracle.sync();
            oracle.check();
        }

        vm.warp(token.openTime() + 14 days);
        vm.roll(block.number + 1);
        token.poke();
        oracle.sync();
        oracle.check();
    }

    function _transfer(FairToken token, address[] memory holders, address sink, uint256 roll) internal {
        address a = holders[roll % holders.length];
        uint256 bal = token.balanceOf(a);
        if (bal == 0) return;
        uint256 pct = 1 + (roll % 100);
        uint256 amt = bal * pct / 100;
        if (amt == 0) amt = 1;
        if (amt > bal) return;
        address to = (roll % 5 == 0) ? holders[(roll / 5) % holders.length] : sink;
        vm.prank(a);
        try token.transfer(to, amt) {} catch {}
    }

    function _tinyBuy(FairToken token, MiniWBNB wbnb, uint256 amountOut) internal {
        address pair = token.pair();
        MiniPair p = MiniPair(pair);
        (uint112 r0, uint112 r1,) = p.getReserves();
        bool token0 = p.token0() == address(token);
        uint256 reserveOut = token0 ? uint256(r0) : uint256(r1);
        if (amountOut == 0 || amountOut >= reserveOut) return;
        wbnb.deposit{value: 0.05 ether}();
        wbnb.transfer(pair, 0.05 ether);
        try p.swap(token0 ? amountOut : 0, token0 ? 0 : amountOut, address(this), "") {} catch {}
    }

    function _buy(FairToken token, MiniRouter router, address a, uint256 pay) internal {
        address[] memory path = new address[](2);
        path[0] = token.wbnb();
        path[1] = address(token);
        vm.prank(a);
        try router.swapExactETHForTokens{value: pay}(0, path, a, block.timestamp) {} catch {}
    }

    function _sell(FairToken token, MiniRouter router, address a, uint256 pct) internal {
        uint256 bal = token.balanceOf(a);
        if (bal < 2) return;
        uint256 amt = bal * pct / 100;
        if (amt == 0) return;
        address[] memory path = new address[](2);
        path[0] = address(token);
        path[1] = token.wbnb();
        vm.startPrank(a);
        token.approve(address(router), amt);
        try router.swapExactTokensForETHSupportingFeeOnTransferTokens(amt, 0, path, a, block.timestamp) {} catch {}
        vm.stopPrank();
    }
}
