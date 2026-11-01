// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {FairToken} from "../src/FairToken.sol";
import {MockAgentIdVerifier} from "./mocks/MockAgentIdVerifier.sol";
import {MiniFactory, MiniRouter, MiniWBNB} from "./mocks/MiniAmm.sol";
import {VestModel} from "./VestModel.sol";

contract VestModelTest is Test {
    uint256 constant PREC = 1e18;
    uint256 public maxDiff;

    MockAgentIdVerifier internal ver;
    MiniWBNB internal wbnb;
    MiniFactory internal factory;
    MiniRouter internal router;
    address internal dev;
    uint256 internal actorNonce;

    function setUp() public {
        ver = new MockAgentIdVerifier();
        wbnb = new MiniWBNB();
        factory = new MiniFactory();
        router = new MiniRouter(address(factory), address(wbnb));
        dev = makeAddr("dev");
    }

    function test_round7SecondForfeitUsesRemainingLocked() public {
        (FairToken t, VestModel m, address[] memory hs) = _crowd(6);
        address a = hs[0];
        _trimToWei(t, m, a);
        _trimToWei(t, m, hs[1]);
        for (uint256 i = 2; i < 6; ++i) _exitAll(t, m, hs[i]);

        vm.warp(t.openTime() + 10.5 days);
        t.poke();
        m.poke(block.timestamp);
        vm.prank(a);
        t.claim();
        m.claim(a, block.timestamp);

        uint256 rate = t.forfeitRateAt(block.timestamp);
        uint256 lockedBefore = _locked(t, a);
        uint256 forfeitedBefore = _forfeited(t, a);
        uint256 mid = t.balanceOf(a);
        _sell(t, m, a, mid / 2);
        uint256 first = _forfeited(t, a) - forfeitedBefore;
        uint256 lockedAfter = _locked(t, a);
        uint256 rest = t.balanceOf(a);
        uint256 modelSecond = _sell(t, m, a, rest);
        uint256 second = _forfeited(t, a) - forfeitedBefore - first;
        uint256 expect = (lockedBefore - first) * rate / PREC;
        uint256 pricedOnOld = lockedBefore * rate / PREC;

        console2.log("round7-second-before", pricedOnOld);
        console2.log("round7-second-after", second);
        console2.log("round7-second-model", modelSecond);

        assertApproxEqAbs(lockedAfter, lockedBefore - first, 20, "first forfeit left the locked balance");
        assertApproxEqAbs(second, expect, 20, "second forfeit is rate times remaining locked");
        assertApproxEqAbs(second, modelSecond, 20, "second forfeit matches the model");
        assertLt(second, pricedOnOld, "second forfeit is not priced on the pre-forfeit lock");

        _finish(t, m, hs);
    }

    function test_freeTokensDoNotForfeitAndMatchModel() public {
        (FairToken t, VestModel m, address[] memory hs) = _crowd(2);
        address a = hs[0];
        address b = hs[1];
        vm.prank(a);
        t.claim();
        m.claim(a, block.timestamp);
        vm.prank(b);
        t.claim();
        m.claim(b, block.timestamp);

        uint256 gift = t.balanceOf(b) / 2;
        vm.prank(b);
        t.transfer(a, gift);
        m.transferOut(b, gift, block.timestamp);
        m.creditFree(a, gift);

        uint256 before = _forfeited(t, a);
        vm.prank(a);
        t.transfer(makeAddr("free-out"), gift);
        uint256 freeTaken = m.transferOut(a, gift, block.timestamp);
        assertEq(freeTaken, 0, "model does not forfeit free tokens");
        assertEq(_forfeited(t, a), before, "contract does not forfeit free tokens");
        assertEq(t.freeBalance(a), 0);

        uint256 spend = t.balanceOf(a) / 2;
        uint256 mark = _forfeited(t, a);
        vm.prank(a);
        t.transfer(makeAddr("base-out"), spend);
        uint256 taken = m.transferOut(a, spend, block.timestamp);
        assertGt(taken, 0, "baseline spend still forfeits");
        assertLe(_gap(_forfeited(t, a) - mark, taken), 100_000, "baseline forfeit matches the model");
        assertLe(_gap(_receivable(t, a), m.receivable(a)), 100_000, "A receivable matches");
        assertLe(_gap(_receivable(t, b), m.receivable(b)), 100_000, "B receivable matches");
    }

    function test_round5SoleTinyHolderMatchesModel() public {
        (FairToken t, VestModel m, address[] memory hs) = _crowd(6);
        _trimToWei(t, m, hs[0]);
        for (uint256 i = 1; i < 6; ++i) _exitAll(t, m, hs[i]);
        vm.warp(t.openTime() + 10.5 days);
        t.poke();
        m.poke(block.timestamp);
        vm.prank(hs[0]);
        t.claim();
        m.claim(hs[0], block.timestamp);
        uint256 before = _forfeited(t, hs[0]);
        uint256 taken = _sell(t, m, hs[0], t.balanceOf(hs[0]));
        assertApproxEqAbs(_forfeited(t, hs[0]) - before, taken, 100_000, "round 5 forfeit");
        _finish(t, m, hs);
    }

    function test_round6TwoHoldersMatchModel() public {
        (FairToken t, VestModel m, address[] memory hs) = _crowd(6);
        _trimToWei(t, m, hs[0]);
        _trimToWei(t, m, hs[1]);
        for (uint256 i = 2; i < 6; ++i) _exitAll(t, m, hs[i]);
        vm.warp(t.openTime() + 10.5 days);
        t.poke();
        m.poke(block.timestamp);
        vm.prank(hs[0]);
        t.claim();
        m.claim(hs[0], block.timestamp);
        uint256 bal = t.balanceOf(hs[0]);
        _sell(t, m, hs[0], bal / 2);
        _sell(t, m, hs[0], t.balanceOf(hs[0]));
        _finish(t, m, hs);
    }

    function testFuzz_sequencesMatchModel(uint8 nRaw, uint256 salt) public {
        uint256 n = bound(uint256(nRaw), 2, 6);
        (FairToken t, VestModel m, address[] memory hs) = _crowd(n);
        _trimToWei(t, m, hs[0]);
        uint256 day = 1;
        for (uint256 step; step < 4; ++step) {
            uint256 room = 13 > day ? 13 - day : 0;
            uint256 jump = room == 0 ? 0 : uint256(keccak256(abi.encode(salt, step))) % (room + 1);
            day += jump;
            _fuzzStep(t, m, hs, n, salt, day);
        }
        _finish(t, m, hs);
        console2.log("fuzz-max-diff", maxDiff);
    }

    function _fuzzStep(
        FairToken t,
        VestModel m,
        address[] memory hs,
        uint256 n,
        uint256 salt,
        uint256 day
    ) internal {
        vm.warp(t.openTime() + day * 1 days);
        t.poke();
        m.poke(block.timestamp);
        address who = hs[uint256(keccak256(abi.encode(salt, day, "who"))) % n];
        vm.prank(who);
        try t.claim() {} catch {}
        m.claim(who, block.timestamp);
        uint256 bal = t.balanceOf(who);
        if (bal <= 1) return;
        uint256 pct = 1 + (uint256(keccak256(abi.encode(salt, day, "pct"))) % 100);
        uint256 amt = bal * pct / 100;
        if (amt == 0) amt = 1;
        uint256 before = _forfeited(t, who);
        uint256 taken = _sell(t, m, who, amt);
        uint256 got = _forfeited(t, who) - before;
        _note(got, taken);
        assertLe(_gap(got, taken), 100_000, "forfeit vs model");
    }

    function _finish(FairToken t, VestModel m, address[] memory hs) internal {
        vm.warp(t.openTime() + 14 days);
        t.poke();
        m.poke(block.timestamp);
        uint256 n = hs.length;
        for (uint256 i; i < n; ++i) {
            vm.prank(hs[i]);
            try t.claim() {} catch {}
            m.claim(hs[i], block.timestamp);
            uint256 got = _receivable(t, hs[i]);
            uint256 fair = m.receivable(hs[i]);
            _note(got, fair);
            assertLe(_gap(got, fair), 100_000, "receivable vs model");
        }
        assertEq(t.pool() + t.vestedOut() + t.burnedLocked() + t.earmark(), t.initialPool());
        assertEq(t.balanceOf(address(t)), t.taxDevReserve() + t.taxLpReserve(), "stranded");
    }

    function _sell(FairToken t, VestModel m, address a, uint256 amt) internal returns (uint256 taken) {
        vm.prank(a);
        t.transfer(makeAddr("sink"), amt);
        taken = m.transferOut(a, amt, block.timestamp);
    }

    function _trimToWei(FairToken t, VestModel m, address a) internal {
        vm.prank(a);
        t.claim();
        m.claim(a, block.timestamp);
        uint256 bal = t.balanceOf(a);
        _sell(t, m, a, bal - 1);
    }

    function _baseline(FairToken t, address a) internal view returns (uint256 b) {
        (,,,,,, b,,,,,) = t.accounts(a);
    }

    function _exitAll(FairToken t, VestModel m, address a) internal {
        vm.prank(a);
        t.claim();
        m.claim(a, block.timestamp);
        uint256 bal = t.balanceOf(a);
        if (bal == 0) return;
        _sell(t, m, a, bal);
    }

    function _crowd(uint256 n) internal returns (FairToken t, VestModel m, address[] memory hs) {
        FairToken.Params memory p = _params();
        p.hardCap = n * 5;
        p.softCap = n;
        p.maxPerWallet = 5;
        p.maxPerIdentity = 5;
        p.tokensPerShare = 3000 ether;
        p.minUnit = 1;
        p.swapThreshold = 1_000_000 ether;
        t = new FairToken(p);
        m = new VestModel(p.tokensPerShare, p.immediateUnlockBps, p.vestCliff, p.vestLinear, p.forfeitFullRate, p.forfeitWindow);
        hs = new address[](n);
        for (uint256 i; i < n; ++i) {
            hs[i] = _actor(keccak256(abi.encode("m", i, actorNonce)));
            (uint256 cost,) = t.quote(5);
            vm.prank(hs[i]);
            t.mint{value: cost}(5);
            m.add(hs[i], 5);
        }
        vm.warp(t.deadline() + 1);
        t.finalize();
        m.finalize(t.openTime());
    }

    function _params() internal view returns (FairToken.Params memory p) {
        p.name = "Fair Mint Token";
        p.symbol = "FMT";
        p.verifier = address(ver);
        p.devWallet = dev;
        p.router = address(router);
        p.factory = address(factory);
        p.wbnb = address(wbnb);
        p.hardCap = 20;
        p.softCap = 4;
        p.tier1Price = 0.004 ether;
        p.tier2Price = 0.005 ether;
        p.tier3Price = 0.006 ether;
        p.tier1Bps = 2500;
        p.tier2Bps = 5000;
        p.maxPerWallet = 20;
        p.maxPerIdentity = 20;
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
        p.swapThreshold = 1_000_000 ether;
        p.minUnit = 1;
    }

    function _actor(bytes32 id) internal returns (address a) {
        actorNonce++;
        a = makeAddr(string(abi.encodePacked("mactor", actorNonce)));
        ver.set(a, id);
        vm.deal(a, 1000 ether);
    }

    function _locked(FairToken t, address a) internal view returns (uint256 locked) {
        (locked,,,) = t.unlockState(a);
    }

    function _forfeited(FairToken t, address a) internal view returns (uint256 forfeitedOut) {
        (,,,,,,,,, forfeitedOut,,) = t.accounts(a);
    }

    function _receivable(FairToken t, address a) internal view returns (uint256) {
        (uint256 locked, uint256 unlocked,,) = t.unlockState(a);
        return unlocked + locked;
    }

    function _gap(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    function _note(uint256 a, uint256 b) internal {
        uint256 g = _gap(a, b);
        if (g > maxDiff) maxDiff = g;
    }
}
