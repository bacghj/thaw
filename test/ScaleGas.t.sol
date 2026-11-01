// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {FairToken} from "../src/FairToken.sol";
import {MockAgentIdVerifier} from "./mocks/MockAgentIdVerifier.sol";
import {MiniFactory, MiniRouter, MiniWBNB} from "./mocks/MiniAmm.sol";

/// @notice Default-sized launch. User calls must not walk the holder set.
contract ScaleGasTest is Test {
    uint256 constant GAS_CAP = 1_000_000;

    function test_sixThousandHoldersStayUnderOneMillionGas() public {
        MockAgentIdVerifier ver = new MockAgentIdVerifier();
        MiniWBNB wbnb = new MiniWBNB();
        MiniFactory factory = new MiniFactory();
        MiniRouter router = new MiniRouter(address(factory), address(wbnb));

        FairToken.Params memory p;
        p.name = "Fair Mint Token";
        p.symbol = "FMT";
        p.verifier = address(ver);
        p.devWallet = makeAddr("dev");
        p.router = address(router);
        p.factory = address(factory);
        p.wbnb = address(wbnb);
        p.hardCap = 30_000;
        p.softCap = 1_000;
        p.tier1Price = 0.004 ether;
        p.tier2Price = 0.005 ether;
        p.tier3Price = 0.006 ether;
        p.tier1Bps = 2500;
        p.tier2Bps = 5000;
        p.maxPerWallet = 5;
        p.maxPerIdentity = 5;
        p.mintDuration = 48 hours;
        p.tokensPerShare = 3000 ether;
        p.premiumNum = 3;
        p.premiumDen = 2;
        p.immediateUnlockBps = 1500;
        p.demandNum = 50;
        p.demandDen = 100;
        p.vestCliff = 7 days;
        p.vestLinear = 7 days;
        p.forfeitFullRate = 3 days;
        p.forfeitWindow = 14 days;
        p.swapThreshold = 1_000_000 ether;
        p.minUnit = 1e12;
        p.mintFeeBps = 1000;
        p.twapWindow = 30 minutes;
        p.twapMaxDeviationBps = 1000;
        FairToken t = new FairToken(p);

        address a0;
        address a1;
        uint256 n = 6_000;
        for (uint256 i; i < n; ++i) {
            address a = address(uint160(0xA000 + i));
            ver.set(a, bytes32(i + 1));
            vm.deal(a, 100 ether);
            (uint256 cost,) = t.quote(5);
            vm.prank(a);
            t.mint{value: cost}(5);
            if (i == 0) a0 = a;
            if (i == 1) a1 = a;
        }
        assertEq(t.sold(), 30_000);
        assertEq(t.activeHolders(), n);
        assertFalse(t.exactMode(), "finalize must not need a holder walk");
        uint256 g0 = gasleft();
        t.finalize();
        uint256 gFinalize = g0 - gasleft();

        vm.prank(a0);
        g0 = gasleft();
        t.claim();
        uint256 gClaim = g0 - gasleft();

        uint256 bal = t.balanceOf(a0);
        vm.prank(a0);
        g0 = gasleft();
        t.transfer(address(0xBEEF), bal);
        uint256 gForfeit = g0 - gasleft();
        assertGt(gForfeit, 0);
        (,,,,,,,,, uint256 forfeited,,) = t.accounts(a0);
        assertGt(forfeited, 0, "baseline transfer forfeited");

        vm.warp(t.openTime() + 10 days);
        vm.roll(block.number + 1);
        t.poke();
        vm.prank(a1);
        g0 = gasleft();
        t.claim();
        uint256 gLater = g0 - gasleft();

        console2.log("gas-finalize", gFinalize);
        console2.log("gas-first-claim", gClaim);
        console2.log("gas-forfeit-transfer", gForfeit);
        console2.log("gas-later-claim", gLater);

        // Pair creation and the LP mint dominate finalize. It does not walk holders.
        assertLt(gFinalize, 1_700_000, "finalize");
        assertLt(gClaim, GAS_CAP, "first claim");
        assertLt(gForfeit, GAS_CAP, "forfeit transfer");
        assertLt(gLater, GAS_CAP, "later claim");
        assertFalse(t.exactMode(), "still on the index after one exit");
    }

    /// @dev The integer walk is only used at or below EXACT_MAX. This records one claim there.
    function test_exactModeClaimGasAtCap() public {
        (FairToken t, address a0) = _launch(6);
        assertTrue(t.exactMode());
        vm.warp(t.openTime() + 10 days);
        vm.roll(block.number + 1);
        vm.prank(a0);
        uint256 g0 = gasleft();
        t.claim();
        uint256 gClaim = g0 - gasleft();
        uint256 bal = t.balanceOf(a0);
        vm.prank(a0);
        g0 = gasleft();
        t.transfer(address(0xBEEF), bal);
        uint256 gForfeit = g0 - gasleft();
        console2.log("gas-exact-claim-6", gClaim);
        console2.log("gas-exact-forfeit-6", gForfeit);
        assertLt(gClaim, GAS_CAP, "exact claim");
        assertLt(gForfeit, GAS_CAP, "exact forfeit");
    }

    function _launch(uint256 n) internal returns (FairToken t, address a0) {
        MockAgentIdVerifier ver = new MockAgentIdVerifier();
        MiniWBNB wbnb = new MiniWBNB();
        MiniFactory factory = new MiniFactory();
        MiniRouter router = new MiniRouter(address(factory), address(wbnb));
        FairToken.Params memory p;
        p.name = "Fair Mint Token";
        p.symbol = "FMT";
        p.verifier = address(ver);
        p.devWallet = makeAddr("dev");
        p.router = address(router);
        p.factory = address(factory);
        p.wbnb = address(wbnb);
        p.hardCap = n;
        p.softCap = 1;
        p.tier1Price = 0.004 ether;
        p.tier2Price = 0.005 ether;
        p.tier3Price = 0.006 ether;
        p.tier1Bps = 2500;
        p.tier2Bps = 5000;
        p.maxPerWallet = 1;
        p.maxPerIdentity = 1;
        p.mintDuration = 48 hours;
        p.tokensPerShare = 3000 ether;
        p.premiumNum = 3;
        p.premiumDen = 2;
        p.immediateUnlockBps = 1500;
        p.demandNum = 50;
        p.demandDen = 100;
        p.vestCliff = 7 days;
        p.vestLinear = 7 days;
        p.forfeitFullRate = 3 days;
        p.forfeitWindow = 14 days;
        p.swapThreshold = 1_000_000 ether;
        p.minUnit = 1;
        FairToken token = new FairToken(p);
        for (uint256 i; i < n; ++i) {
            address a = address(uint160(0xC000 + i));
            ver.set(a, bytes32(i + 1));
            vm.deal(a, 10 ether);
            (uint256 cost,) = token.quote(1);
            vm.prank(a);
            token.mint{value: cost}(1);
            if (i == 0) a0 = a;
        }
        uint256 g0 = gasleft();
        token.finalize();
        console2.log("gas-finalize-n", n);
        console2.log("gas-finalize-small", g0 - gasleft());
        t = token;
    }
}
