// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {FairToken} from "../src/FairToken.sol";
import {AgentIdVerifier, IHandleRegistry} from "../src/verifiers/AgentIdVerifier.sol";
import {MockAgentIdVerifier} from "./mocks/MockAgentIdVerifier.sol";
import {MiniFactory, MiniPair, MiniRouter, MiniWBNB} from "./mocks/MiniAmm.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {EntitlementOracle} from "./EntitlementOracle.sol";

contract ContractMinter {
    function go(FairToken t, uint256 shares) external payable {
        t.mint{value: msg.value}(shares);
    }
}

contract RefundReenter {
    FairToken public token;
    bool public guarded;
    bool public doublePaid;

    constructor(FairToken t) {
        token = t;
    }

    receive() external payable {
        try token.refund() {
            doublePaid = true;
        } catch {
            guarded = true;
        }
    }
}

contract RejectBNB {
    receive() external payable {
        revert("no bnb");
    }
}

contract RoundTrip {
    receive() external payable {}

    function go(FairToken t, MiniRouter r, uint256 bnbIn) external payable returns (uint256 bought) {
        address[] memory path = new address[](2);
        path[0] = t.wbnb();
        path[1] = address(t);
        r.swapExactETHForTokens{value: bnbIn}(0, path, address(this), block.timestamp);
        bought = t.balanceOf(address(this));
        t.approve(address(r), bought);
        address[] memory back = new address[](2);
        back[0] = address(t);
        back[1] = t.wbnb();
        r.swapExactTokensForETHSupportingFeeOnTransferTokens(bought, 0, back, address(this), block.timestamp);
    }
}

contract MockRegistry is IHandleRegistry {
    mapping(address => string) public handleOf;
    mapping(string => address) public ownerOfHandle;

    function set(address account, string calldata handle) external {
        handleOf[account] = handle;
        ownerOfHandle[handle] = account;
    }
}

contract FairTokenTest is Test {
    uint256 constant PREC = 1e18;

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
        p.minUnit = 1e12;
    }

    function _fresh(FairToken.Params memory p) internal returns (FairToken t) {
        t = new FairToken(p);
    }

    function _actor(bytes32 id) internal returns (address a) {
        actorNonce++;
        a = makeAddr(string(abi.encodePacked("actor", actorNonce)));
        ver.set(a, id);
        vm.deal(a, 1000 ether);
    }

    function _mint(FairToken t, address a, uint256 shares) internal {
        (uint256 cost,) = t.quote(shares);
        vm.prank(a);
        t.mint{value: cost}(shares);
    }

    function _acc(FairToken t, address a)
        internal
        view
        returns (uint256 shares, uint256 paid, uint256 claimable, uint256 claimed, uint256 forfeitedOut)
    {
        (shares, paid,,,, claimable,,, claimed, forfeitedOut,,) = t.accounts(a);
    }

    function _fillAndFinalize(FairToken t, address a) internal {
        _mint(t, a, t.hardCap());
        t.finalize();
    }

    function test_quoteSpansTiersAndTokensPerShareAreConstant() public {
        FairToken.Params memory p = _params();
        p.hardCap = 100;
        p.softCap = 10;
        p.maxPerWallet = 100;
        p.maxPerIdentity = 100;
        FairToken t = _fresh(p);
        // 25 tier1 + 5 tier2
        uint256 expected = 25 * p.tier1Price + 5 * p.tier2Price;
        (uint256 cost, uint256 tokens) = t.quote(30);
        assertEq(cost, expected);
        assertEq(tokens, 30 * p.tokensPerShare);
        (uint256 c1,) = t.quote(1);
        assertEq(c1, p.tier1Price);
        // cheaper tier, same tokens => better cost basis
        assertLt(c1 * PREC / p.tokensPerShare, p.tier3Price * PREC / p.tokensPerShare);
    }

    function testFuzz_quoteMonotonic(uint8 a, uint8 b) public {
        FairToken t = _fresh(_params());
        uint256 x = bound(uint256(a), 1, t.hardCap());
        uint256 y = bound(uint256(b), 1, t.hardCap());
        (uint256 cx,) = t.quote(x);
        (uint256 cy,) = t.quote(y);
        if (x <= y) assertLe(cx, cy);
        if (x == y) assertEq(cx, cy);
    }

    function test_mintCapsIdentityWalletAndEoaGate() public {
        FairToken.Params memory p = _params();
        p.hardCap = 30;
        p.softCap = 4;
        p.maxPerWallet = 5;
        p.maxPerIdentity = 5;
        FairToken t = _fresh(p);

        address a = _actor("id-a");
        address b = _actor("id-a"); // same identity, second wallet
        ver.set(b, bytes32("id-a"));
        address c = _actor("id-c");

        _mint(t, a, 3);
        (uint256 cost3,) = t.quote(3);
        vm.prank(b);
        vm.expectRevert(abi.encodeWithSelector(FairToken.IdentityCapExceeded.selector, 5, 3, 3));
        t.mint{value: cost3}(3);
        _mint(t, b, 2);
        (uint256 cost1,) = t.quote(1);
        vm.prank(a);
        vm.expectRevert(abi.encodeWithSelector(FairToken.IdentityCapExceeded.selector, 5, 5, 1));
        t.mint{value: cost1}(1);
        _mint(t, c, 5);
        vm.prank(c);
        vm.expectRevert(abi.encodeWithSelector(FairToken.WalletCapExceeded.selector, 5, 5, 1));
        t.mint{value: cost1}(1);

        address plain = makeAddr("plain");
        vm.deal(plain, 1 ether);
        (uint256 cost,) = t.quote(1);
        vm.prank(plain);
        vm.expectRevert(abi.encodeWithSelector(FairToken.NotAgent.selector, plain));
        t.mint{value: cost}(1);

        ContractMinter bot = new ContractMinter();
        ver.set(address(bot), bytes32("bot"));
        vm.deal(address(bot), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(FairToken.ContractCallerNotAllowed.selector, address(bot)));
        bot.go{value: cost}(t, 1);

        address delegated = makeAddr("delegated");
        ver.set(delegated, bytes32("delegated"));
        vm.deal(delegated, 1 ether);
        vm.etch(delegated, abi.encodePacked(hex"ef0100", bytes20(address(0xBEEF))));
        assertEq(delegated.code.length, 23);
        vm.prank(delegated);
        t.mint{value: cost}(1);
        (uint256 delegatedShares,,,,) = _acc(t, delegated);
        assertEq(delegatedShares, 1);

        address fake = makeAddr("fake7702");
        ver.set(fake, bytes32("fake"));
        vm.deal(fake, 1 ether);
        vm.etch(fake, hex"00112233445566778899aabbccddeeff00112233445566");
        vm.prank(fake);
        vm.expectRevert(abi.encodeWithSelector(FairToken.ContractCallerNotAllowed.selector, fake));
        t.mint{value: cost}(1);

        address payer = _actor("payer");
        (uint256 due,) = t.quote(1);
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(FairToken.WrongPayment.selector, due, due - 1));
        t.mint{value: due - 1}(1);

        assertEq(address(t).balance, t.raised());
    }

    function test_refundReturnsAllAndBlocksFinalize() public {
        FairToken t = _fresh(_params());
        address a = _actor("refund");
        address b = _actor("refund2");
        _mint(t, a, 2);
        _mint(t, b, 1); // 3 < soft cap 4
        (, uint256 paidA,,,) = _acc(t, a);
        uint256 raisedBefore = t.raised();
        vm.warp(t.deadline());
        assertEq(t.currentPhase(), 4);
        t.triggerRefund();
        assertEq(t.currentPhase(), 2);

        uint256 bal = a.balance;
        vm.prank(a);
        t.refund();
        assertEq(a.balance, bal + paidA);
        assertEq(t.raised(), raisedBefore - paidA);
        assertEq(address(t).balance, t.raised());
        vm.expectRevert(FairToken.AlreadyFinalized.selector);
        t.finalize();
        vm.prank(a);
        vm.expectRevert(FairToken.MintClosed.selector);
        t.mint{value: 1}(1);
    }

    function test_refundReentrancyPaysOnce() public {
        FairToken.Params memory p = _params();
        FairToken t = _fresh(p);
        RefundReenter atk = new RefundReenter(t);
        ver.set(address(atk), bytes32("re"));
        vm.deal(address(atk), 10 ether);
        // Look like an EOA only for the mint, then restore the attacking code.
        bytes memory code = address(atk).code;
        vm.etch(address(atk), "");
        (uint256 cost,) = t.quote(1);
        vm.prank(address(atk));
        t.mint{value: cost}(1);
        vm.etch(address(atk), code);
        vm.warp(t.deadline());
        t.triggerRefund();
        vm.prank(address(atk));
        t.refund();
        assertTrue(atk.guarded());
        assertFalse(atk.doublePaid());
        (, uint256 atkPaid,,,) = _acc(t, address(atk));
        assertEq(atkPaid, 0);
        assertEq(address(t).balance, 0);
    }

    function test_cannotRefundAfterSoftCap_earlyFinalizeWhenFull() public {
        FairToken.Params memory p = _params();
        p.hardCap = 4;
        p.softCap = 2;
        p.maxPerWallet = 4;
        FairToken t = _fresh(p);
        address a = _actor("full");
        _mint(t, a, 4);
        vm.warp(t.deadline());
        vm.expectRevert(FairToken.SoftCapMet.selector);
        t.triggerRefund();
        // cap already filled, finalize does not need the deadline
        FairToken t2 = _fresh(p);
        address b = _actor("full2");
        _mint(t2, b, 4);
        assertLt(block.timestamp, t2.deadline());
        t2.finalize();
        assertEq(t2.currentPhase(), 3);
        assertEq(address(t2).balance, 0);
        assertEq(wbnb.balanceOf(t2.pair()), t2.raised());
    }

    function test_finalizePriceExactAndLpBurned() public {
        FairToken t = _fresh(_params());
        address a = _actor("lp");
        _fillAndFinalize(t, a);
        address pair = t.pair();
        uint256 w = wbnb.balanceOf(pair);
        uint256 tokens = t.balanceOf(pair);
        // reserveW / reserveT = premium * average cost
        assertEq(w * t.minterSupply() * t.premiumDen(), tokens * t.raised() * t.premiumNum());
        assertGt(MiniPair(pair).balanceOf(t.DEAD()), 0);
        assertEq(MiniPair(pair).balanceOf(address(t)), 0);
        assertEq(t.totalSupply(), t.minterSupply() + t.lpMinted());
        // transfers were impossible before; supply exists only now
        vm.expectRevert(FairToken.AlreadyFinalized.selector);
        t.finalize();
    }

    function test_pairPrecreatedAndWbnbDonationStillHitsPrice() public {
        FairToken t = _fresh(_params());
        address pair = factory.createPair(address(t), address(wbnb));
        address donor = makeAddr("donor");
        vm.deal(donor, 5 ether);
        vm.startPrank(donor);
        wbnb.deposit{value: 3 ether}();
        wbnb.transfer(pair, 1 ether); // unsynced, must be skimmed
        wbnb.transfer(pair, 2 ether);
        vm.stopPrank();
        MiniPair(pair).sync(); // synced donation of the remaining 2 BNB... 
        // The first 1 BNB was included in the balance before sync, so both are synced.
        // Re-read: both transfers happened before sync, so donated = 3 BNB synced.
        address a = _actor("buyer");
        _fillAndFinalize(t, a);
        assertEq(t.pair(), pair);
        uint256 w = wbnb.balanceOf(pair);
        uint256 tokens = t.balanceOf(pair);
        uint256 lhs = w * t.minterSupply() * t.premiumDen();
        uint256 rhs = tokens * t.raised() * t.premiumNum();
        // mulDiv floors once; the cross-product error is strictly less than the divisor.
        assertApproxEqAbs(lhs, rhs, t.raised() * t.premiumNum());
        assertGt(w, t.raised()); // donation stayed in the pool, price unchanged
    }

    function test_unsyncedDonationIsSkimmedAndPriceUsesOnlyRaised() public {
        FairToken t = _fresh(_params());
        address pair = factory.createPair(address(t), address(wbnb));
        address donor = makeAddr("donor2");
        vm.deal(donor, 2 ether);
        vm.startPrank(donor);
        wbnb.deposit{value: 1 ether}();
        wbnb.transfer(pair, 1 ether);
        vm.stopPrank();
        // no sync
        address a = _actor("buyer2");
        _fillAndFinalize(t, a);
        assertEq(wbnb.balanceOf(pair), t.raised());
        uint256 tokens = t.balanceOf(pair);
        assertEq(t.raised() * t.minterSupply() * t.premiumDen(), tokens * t.raised() * t.premiumNum());
        assertEq(wbnb.balanceOf(t.DEAD()), 1 ether);
    }

    function test_tokenDonationImpossibleAndDirectBnbRejected() public {
        FairToken t = _fresh(_params());
        address a = _actor("nope");
        _mint(t, a, 1);
        vm.prank(a);
        vm.expectRevert(FairToken.TransferDisabled.selector);
        t.transfer(makeAddr("pair"), 1);
        (bool ok,) = address(t).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(address(t).balance, t.raised());
        // router may deliver BNB (swapback), and it is not counted as raised
        uint256 raised = t.raised();
        vm.deal(address(router), 1);
        vm.prank(address(router));
        (bool sent,) = address(t).call{value: 1}("");
        assertTrue(sent);
        assertEq(t.raised(), raised);
    }

    function test_forfeitRateCurveBoundaries() public {
        FairToken t = _fresh(_params());
        address a = _actor("curve");
        _fillAndFinalize(t, a);
        uint256 open = t.openTime();
        uint256 full = t.forfeitFullRate();
        uint256 window = t.forfeitWindow();
        uint256 span = window - full;

        assertEq(t.forfeitRateAt(open), PREC);
        assertEq(t.forfeitRateAt(open + full - 1), PREC);
        assertEq(t.forfeitRateAt(open + full), PREC, "day 3 inclusive is still 100%");
        assertLt(t.forfeitRateAt(open + full + 1), PREC);

        uint256 mid = open + full + span / 2;
        assertEq(t.forfeitRateAt(mid), PREC / 2, "midpoint of the decay is 50%");

        uint256 justBefore = open + window - 1;
        uint256 expected = PREC - ((span - 1) * PREC) / span;
        assertEq(t.forfeitRateAt(justBefore), expected);
        assertGt(expected, 0);
        assertEq(t.forfeitRateAt(open + window), 0, "day 14 is zero");
        assertEq(t.forfeitRateAt(open + window + 10 days), 0);
    }

    function testFuzz_forfeitRateMonotonic(uint32 dt1, uint32 dt2) public {
        FairToken t = _fresh(_params());
        address a = _actor("fuzzrate");
        _fillAndFinalize(t, a);
        uint256 open = t.openTime();
        uint256 x = bound(uint256(dt1), 0, 30 days);
        uint256 y = bound(uint256(dt2), 0, 30 days);
        if (x > y) (x, y) = (y, x);
        assertGe(t.forfeitRateAt(open + x), t.forfeitRateAt(open + y));
    }

    function test_forfeitAtDay3MidAndDay14() public {
        // Day 3: vest has not started, rate is 100%, selling all liquid burns all locked (sole minter).
        FairToken t = _fresh(_params());
        address a = _actor("day3");
        address sink = makeAddr("sink");
        _fillAndFinalize(t, a);
        vm.prank(a);
        t.claim();
        uint256 liquid = t.balanceOf(a);
        (uint256 sharesA,,,,) = _acc(t, a);
        assertEq(liquid, sharesA * t.immediatePerShare());

        vm.warp(t.openTime() + 3 days);
        t.poke();
        (uint256 lockedBefore,,,) = t.unlockState(a);
        assertEq(lockedBefore, sharesA * t.lockedPerShare());
        vm.prank(a);
        t.transfer(sink, liquid);
        (uint256 lockedAfter,,,) = t.unlockState(a);
        assertEq(lockedAfter, 0);
        (,,,, uint256 forfeitedDay3) = _acc(t, a);
        assertEq(forfeitedDay3, lockedBefore);
        assertEq(t.burnedLocked(), lockedBefore);
        assertEq(t.balanceOf(sink), liquid); // wallet transfer is untaxed

        // Mid-decay: 50% of remaining locked. Isolate from the time backstop by pushing the cliff out.
        FairToken.Params memory p = _params();
        p.vestCliff = 30 days;
        p.vestLinear = 7 days;
        FairToken midT = _fresh(p);
        address m = _actor("mid");
        _mint(midT, m, midT.hardCap());
        midT.finalize();
        vm.prank(m);
        midT.claim();
        uint256 open = midT.openTime();
        uint256 span = midT.forfeitWindow() - midT.forfeitFullRate();
        vm.warp(open + midT.forfeitFullRate() + span / 2);
        midT.poke();
        assertEq(midT.forfeitRateAt(block.timestamp), PREC / 2);
        (uint256 lockedMid,,,) = midT.unlockState(m);
        uint256 hold = midT.balanceOf(m);
        vm.prank(m);
        midT.transfer(sink, hold);
        (uint256 lockedMidAfter,,,) = midT.unlockState(m);
        assertEq(lockedMidAfter, lockedMid / 2);
        (,,,, uint256 forfeitedMid) = _acc(midT, m);
        assertEq(forfeitedMid, lockedMid - lockedMidAfter);

        // Day 14: multiplier is 0, and the time backstop has unlocked everything.
        FairToken endT = _fresh(_params());
        address e = _actor("day14");
        _fillAndFinalize(endT, e);
        vm.prank(e);
        endT.claim();
        (,,, uint256 claimed,) = _acc(endT, e);
        vm.warp(endT.openTime() + 14 days);
        endT.poke();
        assertEq(endT.forfeitRateAt(block.timestamp), 0);
        (uint256 lockedEnd, uint256 unlocked, uint256 claimable,) = endT.unlockState(e);
        assertEq(lockedEnd, 0);
        uint256 holdEnd = endT.balanceOf(e);
        uint256 burnedBefore = endT.burnedLocked();
        vm.prank(e);
        endT.transfer(sink, holdEnd);
        assertEq(endT.burnedLocked(), burnedBefore);
        (,,,, uint256 forfeitedEnd) = _acc(endT, e);
        assertEq(forfeitedEnd, 0);
        vm.prank(e);
        endT.claim();
        (uint256 sharesEnd,,, uint256 claimedEnd,) = _acc(endT, e);
        assertEq(claimedEnd, claimed + claimable);
        assertEq(unlocked, claimed + claimable);
        assertEq(claimedEnd, sharesEnd * endT.tokensPerShare());
    }

    function test_splitSalesCannotDodgeForfeit() public {
        FairToken t = _fresh(_params());
        address a = _actor("split");
        address sink = makeAddr("sink2");
        _fillAndFinalize(t, a);
        vm.prank(a);
        t.claim();
        uint256 bal = t.balanceOf(a);
        uint256 chunks = 4;
        uint256 chunk = bal / chunks;
        for (uint256 i; i < chunks; ++i) {
            vm.prank(a);
            t.transfer(sink, chunk);
        }
        (uint256 locked,,,) = t.unlockState(a);
        assertEq(locked, 0);
        (uint256 sharesSplit,,,, uint256 forfeitedSplit) = _acc(t, a);
        assertEq(forfeitedSplit, sharesSplit * t.lockedPerShare());
    }

    function test_forfeitRedistributesToOtherMinter() public {
        FairToken.Params memory p = _params();
        p.hardCap = 8;
        p.softCap = 4;
        p.maxPerWallet = 4;
        FairToken t = _fresh(p);
        address a = _actor("redist-a");
        address b = _actor("redist-b");
        _mint(t, a, 4);
        _mint(t, b, 4);
        t.finalize();
        vm.prank(a);
        t.claim();
        vm.prank(b);
        t.claim();
        (uint256 lockedA,,,) = t.unlockState(a);
        (uint256 lockedB,,,) = t.unlockState(b);
        assertEq(lockedA, lockedB);
        uint256 balA = t.balanceOf(a);
        vm.prank(a);
        t.transfer(makeAddr("out"), balA);
        (uint256 lockedA2,,,) = t.unlockState(a);
        (uint256 lockedB2,,, uint256 gotB) = t.unlockState(b);
        assertEq(lockedA2, 0);
        assertEq(lockedB2, lockedA + lockedB);
        assertGt(gotB, 0);
        (uint256 sharesB,,,,) = _acc(t, b);
        assertEq(t.balanceOf(b), sharesB * t.immediatePerShare());
    }

    function test_demandUnlockCommitsNextBlock_flashRoundTripDoesNot() public {
        FairToken.Params memory p = _params();
        p.demandNum = 1;
        p.demandDen = 1;
        p.hardCap = 8;
        p.softCap = 4;
        p.maxPerWallet = 8;
        FairToken t = _fresh(p);
        address a = _actor("demand");
        _fillAndFinalize(t, a);

        address buyer = makeAddr("buyer");
        vm.deal(buyer, 50 ether);
        address[] memory path = new address[](2);
        path[0] = address(wbnb);
        path[1] = address(t);
        uint256 hwmBefore = t.hwmNet();
        vm.prank(buyer);
        router.swapExactETHForTokens{value: 1 ether}(0, path, buyer, block.timestamp);
        uint256 bought = t.balanceOf(buyer);
        // tax taken, pair sent more than the wallet received
        assertLt(bought, t.totalSupply());
        assertEq(t.hwmNet(), hwmBefore, "same-block buy does not commit");

        vm.roll(block.number + 1);
        t.poke();
        assertGt(t.hwmNet(), 0);
        (uint256 locked,, uint256 claimable,) = t.unlockState(a);
        (uint256 sharesDemand,,,,) = _acc(t, a);
        assertGt(claimable, sharesDemand * t.immediatePerShare());
        assertLt(locked, sharesDemand * t.lockedPerShare());

        // Flash round trip: buy and sell before the next block. HWM stays far below the buy size.
        FairToken t2 = _fresh(p);
        address m = _actor("flash");
        _fillAndFinalize(t2, m);
        RoundTrip rt = new RoundTrip();
        vm.deal(address(rt), 20 ether);
        vm.roll(block.number + 1);
        uint256 size = rt.go{value: 2 ether}(t2, router, 2 ether);
        assertEq(t2.hwmNet(), 0);
        vm.roll(block.number + 1);
        t2.poke();
        assertLt(t2.hwmNet(), size / 2, "round trip must not lock in the gross buy");
    }

    function test_timeBackstopFullyUnlocksByDay14() public {
        FairToken t = _fresh(_params());
        address a = _actor("vest");
        _fillAndFinalize(t, a);
        (uint256 sharesVest,,,,) = _acc(t, a);
        uint256 alloc = sharesVest * t.tokensPerShare();
        vm.warp(t.openTime() + 7 days);
        t.poke();
        (uint256 lockedAtCliff,,,) = t.unlockState(a);
        assertEq(lockedAtCliff, sharesVest * t.lockedPerShare(), "day 7 has not started the linear release");

        vm.warp(t.openTime() + 7 days + 7 days / 2);
        t.poke();
        (uint256 lockedMid,,,) = t.unlockState(a);
        assertApproxEqAbs(lockedMid, lockedAtCliff / 2, 1e15);

        vm.warp(t.openTime() + 14 days);
        t.poke();
        (uint256 lockedEnd,, uint256 claimable,) = t.unlockState(a);
        assertEq(lockedEnd, 0);
        vm.prank(a);
        t.claim();
        assertEq(t.balanceOf(a), alloc);
        assertEq(claimable, alloc);
    }

    function test_taxBuySellWalletAndSwapbackCannotRevertSell() public {
        FairToken.Params memory p = _params();
        p.swapThreshold = 1;
        p.devWallet = address(new RejectBNB());
        FairToken t = _fresh(p);
        address a = _actor("tax");
        _fillAndFinalize(t, a);

        address buyer = makeAddr("taxbuyer");
        vm.deal(buyer, 100 ether);
        address[] memory path = new address[](2);
        path[0] = address(wbnb);
        path[1] = address(t);
        vm.prank(buyer);
        router.swapExactETHForTokens{value: 1 ether}(0, path, buyer, block.timestamp);
        uint256 tax = t.taxDevReserve() + t.taxLpReserve();
        uint256 grossOut = t.balanceOf(buyer) + tax;
        assertGt(grossOut, 0);
        assertEq(tax, grossOut * 300 / 10_000);
        assertEq(t.taxDevReserve(), grossOut * 150 / 10_000);
        assertEq(t.balanceOf(buyer), grossOut - tax);

        // wallet transfer untaxed
        address pal = makeAddr("pal");
        uint256 amt = t.balanceOf(buyer) / 10;
        vm.prank(buyer);
        t.transfer(pal, amt);
        assertEq(t.balanceOf(pal), amt);

        // non-supporting sell reverts; supporting sell survives a reverting dev wallet
        address[] memory back = new address[](2);
        back[0] = address(t);
        back[1] = address(wbnb);
        uint256 sellAmt = t.balanceOf(buyer) / 2;
        vm.startPrank(buyer);
        t.approve(address(router), sellAmt);
        vm.expectRevert();
        router.swapExactTokensForETH(sellAmt, 0, back, buyer, block.timestamp);
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(sellAmt, 0, back, buyer, block.timestamp);
        vm.stopPrank();
        // reserves were not zeroed because swapback reverted
        assertGt(t.taxDevReserve() + t.taxLpReserve(), 0);
    }

    function test_swapbackPaysDevAndBurnsLp() public {
        FairToken.Params memory p = _params();
        p.swapThreshold = 1;
        FairToken t = _fresh(p);
        address a = _actor("swapok");
        _fillAndFinalize(t, a);
        address buyer = makeAddr("swapbuyer");
        vm.deal(buyer, 100 ether);
        address[] memory path = new address[](2);
        path[0] = address(wbnb);
        path[1] = address(t);
        vm.prank(buyer);
        router.swapExactETHForTokens{value: 2 ether}(0, path, buyer, block.timestamp);

        uint256 devBefore = dev.balance;
        uint256 deadLpBefore = MiniPair(t.pair()).balanceOf(t.DEAD());
        address[] memory back = new address[](2);
        back[0] = address(t);
        back[1] = address(wbnb);
        uint256 sellAmt = t.balanceOf(buyer) / 2;
        vm.startPrank(buyer);
        t.approve(address(router), sellAmt);
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(sellAmt, 0, back, buyer, block.timestamp);
        vm.stopPrank();
        assertGt(dev.balance, devBefore);
        assertGt(MiniPair(t.pair()).balanceOf(t.DEAD()), deadLpBefore);
        // Swapback runs before this sell's fee is taken, so only the new fee remains.
        assertEq(t.taxDevReserve(), sellAmt * 150 / 10_000);
        assertEq(t.taxLpReserve(), sellAmt * 300 / 10_000 - sellAmt * 150 / 10_000);
    }

    function test_bnbAccountingRefundsPlusLp() public {
        FairToken t = _fresh(_params());
        address a = _actor("acct");
        address b = _actor("acct2");
        _mint(t, a, 2);
        _mint(t, b, 1);
        uint256 inTotal = t.raised();
        assertEq(address(t).balance, inTotal);
        vm.warp(t.deadline());
        t.triggerRefund();
        (, uint256 refunded,,,) = _acc(t, a);
        vm.prank(a);
        t.refund();
        assertEq(refunded + t.raised(), inTotal);
        assertEq(address(t).balance, t.raised());
        vm.prank(b);
        t.refund();
        assertEq(address(t).balance, 0);
        assertEq(t.raised(), 0);

        FairToken live = _fresh(_params());
        address c = _actor("acct3");
        _fillAndFinalize(live, c);
        assertEq(address(live).balance, 0);
        assertEq(wbnb.balanceOf(live.pair()), live.raised());
        assertEq(live.pool() + live.vestedOut() + live.burnedLocked() + live.earmark(), live.initialPool());
    }

    function test_adapterMatchesHandleAndRejectsMismatch() public {
        MockRegistry reg = new MockRegistry();
        reg.set(address(0xA11CE), "alpha");
        AgentIdVerifier adapter = new AgentIdVerifier(address(reg));
        (bool ok, bytes32 key) = adapter.verify(address(0xA11CE));
        assertTrue(ok);
        assertEq(key, keccak256("alpha"));
        (bool no,) = adapter.verify(address(0xB0B));
        assertFalse(no);

        // forward owner disagrees with reverse record
        MockRegistry bad = new MockRegistry();
        bad.set(address(0xA11CE), "alpha");
        // overwrite forward only
        bad.set(address(0xBEEF), "alpha");
        AgentIdVerifier adapter2 = new AgentIdVerifier(address(bad));
        (bool ok2,) = adapter2.verify(address(0xA11CE));
        assertFalse(ok2);
    }

    function test_deployScriptRefusesMainnetKey() public {
        Deploy d = new Deploy();
        vm.chainId(56);
        vm.setEnv("DEPLOYER_KEY", "1");
        vm.expectRevert(Deploy.MainnetBroadcastForbidden.selector);
        d.run();
    }

    function test_pairSelfSkimDoesNotInflateDemand() public {
        FairToken.Params memory p = _params();
        p.swapThreshold = 1_000_000 ether;
        FairToken t = _fresh(p);
        address a = _actor(bytes32("skim"));
        _fillAndFinalize(t, a);
        _roll();
        vm.prank(a);
        t.claim();
        address pair = t.pair();
        uint256 bal = t.balanceOf(a);
        vm.prank(a);
        t.transfer(pair, bal / 2);
        MiniPair(pair).skim(pair);
        MiniPair(pair).skim(pair);
        MiniPair(pair).skim(pair);
        _roll();
        t.poke();
        assertEq(t.hwmNet(), 0, "self-skim");
    }

    function test_skimToUserAndSyncDoNotCreateDemand() public {
        FairToken.Params memory p = _params();
        p.swapThreshold = 1_000_000 ether;
        FairToken t = _fresh(p);
        address a = _actor(bytes32("sync"));
        _fillAndFinalize(t, a);
        _roll();
        vm.prank(a);
        t.claim();
        address pair = t.pair();
        uint256 first = t.balanceOf(a) / 4;
        vm.prank(a);
        t.transfer(pair, first);
        MiniPair(pair).sync();
        _roll();
        t.poke();
        assertEq(t.hwmNet(), 0, "sync");

        uint256 second = t.balanceOf(a) / 4;
        vm.prank(a);
        t.transfer(pair, second);
        MiniPair(pair).skim(a);
        _roll();
        t.poke();
        assertEq(t.hwmNet(), 0, "skim out");
    }

    function test_sameBlockRoundTripDoesNotLockGrossBuy() public {
        FairToken.Params memory p = _params();
        p.swapThreshold = 1_000_000 ether;
        FairToken t = _fresh(p);
        address a = _actor(bytes32("rt"));
        _fillAndFinalize(t, a);
        _roll();
        RoundTrip trip = new RoundTrip();
        uint256 bought = trip.go{value: 1 ether}(t, router, 1 ether);
        _roll();
        t.poke();
        assertLt(t.hwmNet(), bought, "gross buy");
        assertLt(t.hwmNet(), bought / 2, "same-block net");
    }

    function test_realBuyStillRaisesHighWater() public {
        FairToken.Params memory p = _params();
        p.swapThreshold = 1_000_000 ether;
        FairToken t = _fresh(p);
        address a = _actor(bytes32("buy"));
        _fillAndFinalize(t, a);
        _roll();
        address[] memory path = new address[](2);
        path[0] = address(wbnb);
        path[1] = address(t);
        router.swapExactETHForTokens{value: 1 ether}(0, path, a, block.timestamp);
        _roll();
        t.poke();
        assertGt(t.hwmNet(), 0);
    }

    function test_partialAutoLpKeepsLeftoversAndReusesThem() public {
        FairToken.Params memory p = _params();
        p.swapThreshold = 1 ether;
        p.minUnit = 1e12;
        FairToken t = _fresh(p);
        address a = _actor(bytes32("lp"));
        _fillAndFinalize(t, a);
        assertEq(address(t).balance, 0, "pool open holds no BNB");
        assertGt(MiniPair(t.pair()).balanceOf(t.DEAD()), 0, "LP burned");

        router.setLiquidityUse(5000, 5000);
        _roll();
        vm.prank(a);
        t.claim();
        address[] memory back = new address[](2);
        back[0] = address(t);
        back[1] = address(wbnb);
        uint256 sellAmt = t.balanceOf(a) / 3;
        vm.startPrank(a);
        t.approve(address(router), type(uint256).max);
        // First sell only accrues tax. Swapback runs on a later sell, before that sell's fee.
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(sellAmt, 0, back, a, block.timestamp);
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(sellAmt, 0, back, a, block.timestamp);
        vm.stopPrank();

        uint256 sellFeeLp = sellAmt * 150 / 10_000;
        uint256 leftoverTokens = t.taxLpReserve();
        uint256 leftoverBnb = address(t).balance;
        assertGt(leftoverTokens, sellFeeLp, "unused LP tokens stay reserved");
        assertGt(leftoverBnb, 0, "refunded BNB stays for the next add");
        uint256 devBefore = dev.balance;
        assertGt(devBefore, 0, "dev half swapped");

        router.setLiquidityUse(10_000, 10_000);
        uint256 sell2 = t.balanceOf(a) / 2;
        vm.startPrank(a);
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(sell2, 0, back, a, block.timestamp);
        vm.stopPrank();

        assertLt(address(t).balance, leftoverBnb, "prior BNB was reused");
        assertLt(t.taxLpReserve(), leftoverTokens, "prior tokens were reused");
        assertEq(address(t).balance, 0);
        assertGt(dev.balance, devBefore);
        vm.prank(dev);
        (bool pulled,) = address(t).call(abi.encodeWithSignature("withdraw()"));
        assertFalse(pulled);
    }

    /// @notice Default params. A is left on a few vest points while everyone else exits,
    ///         so later forfeits land on a huge token balance and a tiny point balance.
    ///         The point deduction rounds to 0. That forfeit must still not be claimable.
    function test_tinyPointsCannotSkipLargeForfeit() public {
        FairToken.Params memory p = _params();
        p.hardCap = 30_000;
        p.softCap = 1_000;
        p.maxPerWallet = 5;
        p.maxPerIdentity = 5;
        p.tokensPerShare = 3000 ether;
        p.minUnit = 1;
        p.swapThreshold = 1_000_000 ether;
        FairToken t = _fresh(p);

        address[] memory holders = new address[](200);
        holders[0] = _actor(bytes32("tiny-A"));
        address a = holders[0];
        _mint(t, a, 5);
        for (uint256 i = 1; i < 200; ++i) {
            holders[i] = _actor(bytes32(uint256(0x1000) + i));
            _mint(t, holders[i], 5);
        }
        vm.warp(t.deadline() + 1);
        t.finalize();

        vm.prank(a);
        t.claim();
        uint256 almost = t.balanceOf(a) - 1;
        vm.prank(a);
        t.transfer(makeAddr("sink-a"), almost);
        (,, uint256 pointsA,,,,,,,,,) = t.accounts(a);
        assertGt(pointsA, 0, "A keeps a locked residue");
        assertLt(pointsA, 5 * t.lockedPerShare(), "residue is smaller than the original lock");

        for (uint256 i = 1; i < 200; ++i) {
            vm.prank(holders[i]);
            t.claim();
            uint256 bal = t.balanceOf(holders[i]);
            if (bal > 0) {
                vm.prank(holders[i]);
                t.transfer(makeAddr("sink-rest"), bal);
            }
        }
        assertApproxEqRel(t.totalPoints(), t.rawOf(a), 1e15, "everyone else left the vest");

        vm.warp(t.openTime() + 10.5 days);
        t.poke();
        vm.prank(a);
        t.claim();
        uint256 mid = t.balanceOf(a);
        assertGt(mid, 500_000 ether, "day 10.5 vest is about half the pool");

        (uint256 lockedBefore,,,) = t.unlockState(a);
        (,,,,,,,,, uint256 forfeitedBefore,,) = t.accounts(a);
        uint256 rate = t.forfeitRateAt(block.timestamp);
        uint256 expectForfeit = lockedBefore * rate / PREC;
        assertGt(expectForfeit, 200_000 ether, "legitimate forfeit is hundreds of thousands");

        vm.prank(a);
        t.transfer(makeAddr("sink-mid"), mid);
        (,,,,,,,,, uint256 forfeitedAfter,,) = t.accounts(a);
        uint256 applied = forfeitedAfter - forfeitedBefore;
        assertEq(_forfeitWei(t, a), 0, "no whole-wei forfeit left pending");
        assertApproxEqAbs(applied, expectForfeit, 1000, "forfeit applied");
        assertGt(applied, 200_000 ether, "hundreds of thousands were actually forfeited");

        vm.warp(t.openTime() + 14 days);
        t.poke();
        vm.prank(a);
        t.claim();
        uint256 second = t.balanceOf(a);
        // Before the fix this claim was the whole remaining lock, forfeit included.
        assertApproxEqAbs(second + applied, lockedBefore, 2_000_000, "forfeit is not claimable at day 14");
        assertApproxEqAbs(second, lockedBefore - expectForfeit, 1000, "day-14 claim is the unforfeited remainder");
        assertEq(_forfeitWei(t, a), 0, "day-14 claim did not revive a pending forfeit");
        assertEq(t.pool() + t.vestedOut() + t.burnedLocked() + t.earmark(), t.initialPool());
    }

    /// @notice Two holders stay in the vest. A forfeits twice at day 10.5. After both settle
    ///         on day 14, nothing is stranded and the first forfeit is still enforced.
    function test_twoHoldersForfeitIsSettled() public {
        FairToken.Params memory p = _params();
        p.hardCap = 30_000;
        p.softCap = 1_000;
        p.maxPerWallet = 5;
        p.maxPerIdentity = 5;
        p.tokensPerShare = 3000 ether;
        p.minUnit = 1;
        p.swapThreshold = 1_000_000 ether;
        FairToken t = _fresh(p);

        address[] memory holders = new address[](200);
        holders[0] = _actor(bytes32("pair-A"));
        holders[1] = _actor(bytes32("pair-B"));
        address a = holders[0];
        address b = holders[1];
        for (uint256 i; i < 200; ++i) {
            if (i > 1) holders[i] = _actor(bytes32(uint256(0x2000) + i));
            _mint(t, holders[i], 5);
        }
        vm.warp(t.deadline() + 1);
        t.finalize();

        for (uint256 i; i < 2; ++i) {
            vm.prank(holders[i]);
            t.claim();
            uint256 bal = t.balanceOf(holders[i]);
            vm.prank(holders[i]);
            t.transfer(makeAddr("pair-trim"), bal - 1);
        }
        for (uint256 i = 2; i < 200; ++i) {
            vm.prank(holders[i]);
            t.claim();
            uint256 bal = t.balanceOf(holders[i]);
            if (bal > 0) {
                vm.prank(holders[i]);
                t.transfer(makeAddr("pair-exit"), bal);
            }
        }
        assertApproxEqRel(t.totalPoints(), t.rawOf(a) + t.rawOf(b), 1e15, "only A and B remain");

        vm.warp(t.openTime() + 10.5 days);
        t.poke();
        vm.prank(a);
        t.claim();
        uint256 mid = t.balanceOf(a);
        (uint256 lockedBefore,,,) = t.unlockState(a);
        (,,,,,,,,, uint256 forfeitedBefore,,) = t.accounts(a);
        vm.prank(a);
        t.transfer(makeAddr("pair-mid-1"), mid / 2);
        (,,,,,,,,, uint256 forfeitedMid,,) = t.accounts(a);
        uint256 firstForfeit = forfeitedMid - forfeitedBefore;

        uint256 rest = t.balanceOf(a);
        vm.prank(a);
        t.transfer(makeAddr("pair-mid-2"), rest);
        (,,,,,,,,, uint256 forfeitedAfter,,) = t.accounts(a);
        assertGt(forfeitedAfter, forfeitedMid, "second forfeit landed");
        assertGt(forfeitedAfter - forfeitedBefore, 100_000 ether, "a large forfeit was recorded");

        vm.warp(t.openTime() + 14 days);
        t.poke();
        vm.prank(a);
        t.claim();
        vm.prank(b);
        t.claim();
        t.poke();
        vm.prank(a);
        try t.claim() {} catch {}
        vm.prank(b);
        try t.claim() {} catch {}

        uint256 held = t.balanceOf(address(t)) - t.taxDevReserve() - t.taxLpReserve();
        assertEq(held, 0, "vest tokens stranded in the contract");
        assertEq(t.pool(), 0);
        assertEq(t.earmark(), 0);
        assertEq(t.claimedTotal() + t.burnedLocked(), t.minterSupply(), "claimed plus burned is the whole mint");
    }

    function _points(FairToken t, address a) internal view returns (uint256 pts) {
        (,, pts,,,,,,,,,) = t.accounts(a);
    }

    /// @notice Tiny residual points, large token forfeit. The oracle must reject a forfeit
    ///         that was computed and then left claimable.
    function testFuzz_tinyPointLargeForfeit(uint8 remainRaw, uint8 exitRaw, uint256 salt) public {
        uint256 remain = bound(uint256(remainRaw), 1, 5);
        uint256 exiting = bound(uint256(exitRaw), 1, 3);
        uint256 n = remain + exiting;
        FairToken.Params memory p = _params();
        p.hardCap = n * 2;
        p.softCap = 2;
        p.maxPerWallet = 2;
        p.maxPerIdentity = 2;
        p.tokensPerShare = 3000 ether;
        p.minUnit = 1;
        p.swapThreshold = 1_000_000 ether;
        FairToken t = _fresh(p);
        address[] memory holders = new address[](n);
        for (uint256 i; i < n; ++i) {
            holders[i] = _actor(keccak256(abi.encode(salt, i)));
            _mint(t, holders[i], 2);
        }
        t.finalize();
        EntitlementOracle oracle = new EntitlementOracle(t, holders);
        address a = holders[0];
        vm.prank(a);
        t.claim();
        oracle.sync();
        uint256 keep = t.balanceOf(a);
        vm.prank(a);
        t.transfer(makeAddr("fuzz-trim"), keep - 1);
        oracle.sync();
        oracle.check();
        for (uint256 i = 1; i < n; ++i) {
            vm.prank(holders[i]);
            t.claim();
            uint256 bal = t.balanceOf(holders[i]);
            if (bal == 0) {
                oracle.sync();
                continue;
            }
            vm.prank(holders[i]);
            if (i < remain) t.transfer(makeAddr("fuzz-trim"), bal - 1);
            else t.transfer(makeAddr("fuzz-exit"), bal);
            oracle.sync();
            oracle.check();
        }
        vm.warp(t.openTime() + 10.5 days);
        t.poke();
        oracle.sync();
        oracle.check();
        vm.prank(a);
        t.claim();
        oracle.sync();
        uint256 mid = t.balanceOf(a);
        (uint256 lockedBefore,,,) = t.unlockState(a);
        if (mid > 0) {
            vm.prank(a);
            t.transfer(makeAddr("fuzz-mid"), mid);
        }
        oracle.sync();
        oracle.check();
        assertEq(_forfeitWei(t, a), 0, "forfeit not applied");
        vm.warp(t.openTime() + 14 days);
        t.poke();
        oracle.sync();
        oracle.check();
        vm.prank(a);
        try t.claim() {} catch {}
        oracle.sync();
        oracle.check();
        if (lockedBefore > 0 && mid > 0) {
            assertLt(t.balanceOf(a), lockedBefore, "residual points kept a large forfeit");
        }
        assertEq(t.pool() + t.vestedOut() + t.burnedLocked() + t.earmark(), t.initialPool());
    }

    function _forfeitWei(FairToken t, address a) internal view returns (uint256 weiDust) {
        (,,,,,,,,,, uint256 dust,) = t.accounts(a);
        return dust / PREC;
    }

    /// @notice Default-size supply. After a partial vest, A moves the whole liquid balance.
    ///         The forfeit should come only out of what is still locked. Day 14 must still
    ///         pay the locked remainder. Keeping the pre-forfeit debt drops that remainder
    ///         by the forfeit amount a second time.
    function test_defaultForfeitDoesNotEraseLaterVest() public {
        FairToken.Params memory p = _params();
        p.hardCap = 30_000;
        p.softCap = 1_000;
        p.maxPerWallet = 5;
        p.maxPerIdentity = 5;
        p.tokensPerShare = 3000 ether;
        p.minUnit = 1;
        p.swapThreshold = 1_000_000 ether;
        FairToken t = _fresh(p);

        address[] memory holders = new address[](200);
        holders[0] = _actor(bytes32("forfeit-A"));
        address a = holders[0];
        _mint(t, a, 5);
        for (uint256 i = 1; i < 200; ++i) {
            holders[i] = _actor(bytes32(i));
            _mint(t, holders[i], 5);
        }
        vm.warp(t.deadline() + 1);
        t.finalize();
        EntitlementOracle oracle = new EntitlementOracle(t, holders);

        vm.warp(t.openTime() + 10.5 days);
        t.poke();
        oracle.sync();
        oracle.check();
        vm.prank(a);
        t.claim();
        uint256 liquid = t.balanceOf(a);
        (uint256 lockedBefore,,,) = t.unlockState(a);
        assertGt(liquid, 0);
        assertGt(lockedBefore, 0);

        vm.prank(a);
        t.transfer(makeAddr("sink"), liquid);
        oracle.sync();
        oracle.check();
        (,,,,,,,,, uint256 forfeitedOut,,) = t.accounts(a);
        assertGt(forfeitedOut, 0);
        assertLt(forfeitedOut, lockedBefore);

        uint256 rate = t.forfeitRateAt(t.openTime() + 10.5 days);
        assertApproxEqAbs(forfeitedOut, lockedBefore * rate / PREC, 2, "legitimate forfeit");

        vm.warp(t.openTime() + 14 days);
        t.poke();
        oracle.sync();
        oracle.check();
        vm.prank(a);
        t.claim();
        oracle.sync();
        oracle.check();
        uint256 second = t.balanceOf(a);
        uint256 remaining = lockedBefore - forfeitedOut;
        // Remainder of the locked balance after the single forfeit, plus at most A's
        // share of the redistribution. Not that remainder minus the forfeit again.
        // Index dust on a 200-holder forfeit: the day-14 claim trails the
        // pre-forfeit remainder by a few thousand wei.
        assertGe(second + 20_000, remaining, "later vest missing the forfeited amount");
        assertLt(second, lockedBefore, "forfeited lock paid back in full");
        (,,,,,,, uint256 received,,,,) = t.accounts(a);
        if (second > remaining) {
            assertLe(second - remaining, received + 1000, "extra claim exceeds redistribution");
        }
    }

    /// @notice Buy 10, A transfers 12_006 inside the full-forfeit window, buy 2.
    ///         Released total is 3; the debt reset lets A and B claim 4.
    function test_forfeitBetweenDustReleasesCannotOverclaim() public {
        FairToken.Params memory p = _params();
        p.hardCap = 8;
        p.softCap = 4;
        p.maxPerWallet = 4;
        p.maxPerIdentity = 4;
        p.tokensPerShare = 30_000;
        p.minUnit = 1;
        p.swapThreshold = 1_000_000 ether;
        FairToken t = _fresh(p);
        address a = _actor(bytes32("A"));
        address b = _actor(bytes32("B"));
        _mint(t, a, 4);
        _mint(t, b, 4);
        t.finalize();
        address[] memory holders = new address[](2);
        holders[0] = a;
        holders[1] = b;
        EntitlementOracle oracle = new EntitlementOracle(t, holders);
        vm.prank(a);
        t.claim();
        vm.prank(b);
        t.claim();
        oracle.sync();
        oracle.check();

        _swapOut(t, 10);
        _roll();
        t.poke();
        oracle.sync();
        oracle.check();
        uint256 amt = 12_006;
        vm.prank(a);
        t.transfer(makeAddr("outsider"), amt);
        oracle.sync();
        oracle.check();
        _swapOut(t, 2);
        _roll();
        t.poke();
        oracle.sync();
        oracle.check();

        vm.prank(a);
        try t.claim() {} catch {}
        vm.prank(b);
        try t.claim() {} catch {}
        oracle.sync();
        oracle.check();

        uint256 immediate = 4 * t.immediatePerShare() * 2;
        uint256 vestPaid = t.claimedTotal() - immediate;
        assertLe(vestPaid, t.vestedOut(), "A+B vest claims within released");
        assertGe(t.balanceOf(address(t)), t.pool() + t.earmark() + t.taxDevReserve() + t.taxLpReserve());
    }

    /// @notice Reviewer counterexample: buy 6 wei, poke, buy 2 wei, poke.
    ///         The old index releases 2 and lets the sole holder claim 3.
    function test_twoRoundDustBuysCannotOverclaim() public {
        FairToken.Params memory p = _params();
        p.hardCap = 8;
        p.softCap = 4;
        p.maxPerWallet = 8;
        p.maxPerIdentity = 8;
        p.tokensPerShare = 30_000;
        p.swapThreshold = 1_000_000 ether;
        FairToken t = _fresh(p);
        address a = _actor(bytes32("two-round"));
        _fillAndFinalize(t, a);
        vm.prank(a);
        t.claim();
        uint256 held = t.balanceOf(a);

        _swapOut(t, 6);
        _roll();
        t.poke();
        _swapOut(t, 2);
        _roll();
        t.poke();

        vm.prank(a);
        try t.claim() {} catch {}
        uint256 vestClaimed = t.balanceOf(a) - held;
        assertLe(vestClaimed, t.vestedOut(), "claims within released");
        assertEq(t.pool() + t.vestedOut() + t.burnedLocked() + t.earmark(), t.initialPool());
        assertGe(t.balanceOf(address(t)), t.pool() + t.earmark());
    }

    function test_smallSupplyVestCannotClaimUnreleased() public {
        FairToken.Params memory p = _params();
        p.hardCap = 8;
        p.softCap = 4;
        p.maxPerWallet = 8;
        p.maxPerIdentity = 8;
        p.tokensPerShare = 30_000;
        p.swapThreshold = 1_000_000 ether;
        FairToken t = _fresh(p);
        address a = _actor(bytes32("dust"));
        _fillAndFinalize(t, a);
        vm.prank(a);
        t.claim();
        uint256 held = t.balanceOf(a);
        _swapOut(t, 2);
        _roll();
        t.poke();
        _swapOut(t, 2);
        _roll();
        t.poke();
        (,, uint256 claimable,) = t.unlockState(a);
        if (claimable > 0) {
            vm.prank(a);
            t.claim();
        }
        uint256 vestClaimed = t.balanceOf(a) - held;
        assertGe(t.vestedOut(), vestClaimed, "claim within released");
        assertEq(t.pool() + t.vestedOut() + t.burnedLocked() + t.earmark(), t.initialPool());
        assertGe(t.balanceOf(address(t)), t.pool() + t.earmark());
    }

    function test_defaultSupplyReleaseMatchesClaim() public {
        FairToken.Params memory p = _params();
        p.swapThreshold = 1_000_000 ether;
        FairToken t = _fresh(p);
        address a = _actor(bytes32("def"));
        _fillAndFinalize(t, a);
        assertGt(t.initialPool(), 1e18, "default points exceed the wad");
        vm.prank(a);
        t.claim();
        uint256 held = t.balanceOf(a);
        address[] memory path = new address[](2);
        path[0] = address(wbnb);
        path[1] = address(t);
        router.swapExactETHForTokens{value: 1 ether}(0, path, address(this), block.timestamp);
        _roll();
        t.poke();
        (,, uint256 claimable,) = t.unlockState(a);
        assertGt(claimable, 0);
        vm.prank(a);
        t.claim();
        assertEq(t.balanceOf(a) - held, t.vestedOut());
    }

    function testFuzz_manyTinyRoundsConserveVest(uint256 rounds, uint256 salt) public {
        rounds = bound(rounds, 2, 16);
        FairToken.Params memory p = _params();
        p.hardCap = 8;
        p.softCap = 4;
        p.maxPerWallet = 2;
        p.maxPerIdentity = 2;
        p.tokensPerShare = 30_000;
        p.swapThreshold = 1_000_000 ether;
        FairToken t = _fresh(p);
        address[] memory holders = new address[](4);
        for (uint256 i; i < 4; ++i) {
            holders[i] = _actor(bytes32(i + 1));
            _mint(t, holders[i], 2);
        }
        t.finalize();
        for (uint256 r; r < rounds; ++r) {
            uint256 amt = (uint256(keccak256(abi.encode(salt, r))) % 30) + 1;
            _swapOut(t, amt);
            _roll();
            t.poke();
            _assertVestConserved(t, holders);
        }
    }

    function _assertVestConserved(FairToken t, address[] memory holders) internal view {
        uint256 sum;
        for (uint256 i; i < holders.length; ++i) {
            (uint256 shares,, uint256 points,,,,,,,,, bool materialized) = t.accounts(holders[i]);
            uint256 pts = materialized ? points : shares * t.lockedPerShare();
            sum += pts * t.accVest() / PREC;
        }
        assertLe(sum, t.vestedOut());
        assertGe(t.balanceOf(address(t)), t.pool() + t.earmark() + t.taxDevReserve() + t.taxLpReserve());
        assertEq(t.pool() + t.vestedOut() + t.burnedLocked() + t.earmark(), t.initialPool());
    }

    function testFuzz_releaseNeverPaysMoreThanVested(uint256 amountOut) public {
        amountOut = bound(amountOut, 2, 50_000);
        FairToken.Params memory p = _params();
        p.hardCap = 8;
        p.softCap = 4;
        p.maxPerWallet = 8;
        p.maxPerIdentity = 8;
        p.tokensPerShare = 30_000;
        p.swapThreshold = 1_000_000 ether;
        FairToken t = _fresh(p);
        address a = _actor(bytes32("fuzz"));
        _fillAndFinalize(t, a);
        vm.prank(a);
        t.claim();
        uint256 held = t.balanceOf(a);
        _swapOut(t, amountOut);
        _roll();
        t.poke();
        (,, uint256 claimable,) = t.unlockState(a);
        if (claimable > 0) {
            vm.prank(a);
            t.claim();
        }
        assertGe(t.vestedOut(), t.balanceOf(a) - held);
        assertEq(t.pool() + t.vestedOut() + t.burnedLocked() + t.earmark(), t.initialPool());
    }

    function _roll() internal {
        vm.roll(block.number + 1);
    }

    function _swapOut(FairToken t, uint256 amountOut) internal {
        address pair = t.pair();
        MiniPair p = MiniPair(pair);
        bool token0 = p.token0() == address(t);
        wbnb.deposit{value: 1 ether}();
        wbnb.transfer(pair, 1 ether);
        p.swap(token0 ? amountOut : 0, token0 ? 0 : amountOut, address(this), "");
    }

    function test_deployGas() public {
        FairToken.Params memory p = _params();
        uint256 beforeGas = gasleft();
        new FairToken(p);
        uint256 used = beforeGas - gasleft();
        console2.log("deploy-gas", used);
        assertGt(used, 100_000);
        assertLt(used, 20_000_000);
    }

}
