// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {FairToken} from "../src/FairToken.sol";
import {MockAgentIdVerifier} from "./mocks/MockAgentIdVerifier.sol";
import {MiniFactory, MiniPair, MiniRouter, MiniWBNB} from "./mocks/MiniAmm.sol";

contract FeeReenter {
    FairToken public token;
    uint256 public tries;

    function set(FairToken t) external {
        token = t;
    }

    receive() external payable {
        tries++;
        if (address(token) != address(0) && tries == 1) {
            try token.mint{value: msg.value}(1) {} catch {}
        }
    }
}

contract OpenMintTest is Test {
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

    function test_finalizeSendsTenPercentAndKeepsPremiumPrice() public {
        FairToken t = _openReady(4, 1000);
        address a = _actor("sub");
        _mint(t, a, 4);
        uint256 raised = t.raised();
        uint256 devBefore = dev.balance;
        t.finalize();

        uint256 fee = raised * 1000 / 10_000;
        assertEq(dev.balance - devBefore, fee, "10% of the raise");
        assertEq(wbnb.balanceOf(t.pair()), raised - fee, "90% paired");
        assertEq(address(t).balance, 0);
        assertGt(MiniPair(t.pair()).balanceOf(t.DEAD()), 0);
        assertEq(MiniPair(t.pair()).balanceOf(address(t)), 0);

        uint256 w = wbnb.balanceOf(t.pair());
        uint256 tokens = t.balanceOf(t.pair());
        assertApproxEqAbs(
            w * t.minterSupply() * t.premiumDen(),
            tokens * raised * t.premiumNum(),
            raised,
            "open price is premium times the average mint cost"
        );
    }

    function test_failedSoftCapRefundsEverything() public {
        FairToken t = _openReady(8, 1000);
        address a = _actor("refund");
        _mint(t, a, 2);
        uint256 paid = t.raised();
        uint256 devBefore = dev.balance;
        vm.warp(t.deadline());
        t.triggerRefund();
        uint256 bal = a.balance;
        vm.prank(a);
        t.refund();
        assertEq(a.balance, bal + paid);
        assertEq(dev.balance, devBefore);
        assertEq(address(t).balance, 0);
    }

    function test_openMintHappyPathAndHardCap() public {
        FairToken t = _openReady(4, 1000);
        address a = _actor("a");
        _mint(t, a, 2);
        vm.warp(t.deadline());
        t.finalize();
        vm.warp(block.timestamp + 30 minutes + 1);
        vm.roll(block.number + 1);
        t.poke();

        address b = _actor("b");
        (uint256 cost, uint256 tokens) = t.quoteOpen(1);
        assertEq(tokens, t.tokensPerShare());
        uint256 spotBefore = t.spotPrice();
        uint256 devBefore = dev.balance;
        uint256 pairWbnb = wbnb.balanceOf(t.pair());
        uint256 deadLp = MiniPair(t.pair()).balanceOf(t.DEAD());

        vm.deal(b, cost);
        vm.prank(b);
        t.mint{value: cost}(1);

        assertEq(t.balanceOf(b), t.tokensPerShare());
        assertEq(t.sold(), 3);
        assertEq(dev.balance - devBefore, cost * 1000 / 10_000);
        assertEq(wbnb.balanceOf(t.pair()) - pairWbnb, cost - cost * 1000 / 10_000);
        assertGt(MiniPair(t.pair()).balanceOf(t.DEAD()), deadLp);
        assertEq(MiniPair(t.pair()).balanceOf(address(t)), 0);
        assertApproxEqAbs(t.spotPrice(), spotBefore, spotBefore / 1000 + 1, "add does not move the price");
        assertEq(_vestShares(t, b), 0, "open mint is not a vesting share");

        (uint256 cost2,) = t.quoteOpen(1);
        vm.deal(b, cost2);
        vm.prank(b);
        t.mint{value: cost2}(1);
        assertEq(t.sold(), 4);
        vm.deal(b, cost);
        vm.prank(b);
        vm.expectRevert();
        t.mint{value: cost}(1);
        assertEq(t.sold(), t.hardCap());
    }

    function test_lifetimeCapCoversBothPhases() public {
        FairToken t = _openReady(20, 1000);
        address a = _actor("life-a");
        address b = _actorSame(a, "life-b");
        _mint(t, a, 3);
        for (uint256 i; i < 7; ++i) _mint(t, _actor(bytes32(uint256(0x100) + i)), 1);
        vm.warp(t.deadline());
        t.finalize();
        _readyTwap(t);

        (uint256 cost,) = t.quoteOpen(2);
        vm.deal(b, cost);
        vm.prank(b);
        t.mint{value: cost}(2);
        assertEq(t.idShares(ver.idOf(a)), 5);

        (uint256 one,) = t.quoteOpen(1);
        vm.deal(a, one);
        vm.prank(a);
        vm.expectRevert(abi.encodeWithSelector(FairToken.IdentityCapExceeded.selector, 5, 5, 1));
        t.mint{value: one}(1);
    }

    function test_sameBlockSwapDoesNotChangeMintPriceOrPay() public {
        FairToken t = _openReady(8, 1000);
        address a = _actor("seed");
        _mint(t, a, 4);
        vm.warp(t.deadline());
        t.finalize();
        _readyTwap(t);

        (uint256 cost,) = t.quoteOpen(1);
        address attacker = _actor("atk");
        vm.deal(attacker, 50 ether);
        address[] memory path = new address[](2);
        path[0] = address(wbnb);
        path[1] = address(t);
        vm.prank(attacker);
        router.swapExactETHForTokens{value: 5 ether}(0, path, attacker, block.timestamp);

        (uint256 costAfter,) = t.quoteOpen(1);
        assertEq(costAfter, cost, "same-block swap does not cheapen the mint");
        vm.expectRevert(FairToken.TwapDeviation.selector);
        vm.prank(attacker);
        t.mint{value: costAfter}(1);
    }

    function test_openMintRoundTripLosesTheFee() public {
        FairToken t = _openReady(8, 1000);
        address a = _actor("seed2");
        _mint(t, a, 4);
        vm.warp(t.deadline());
        t.finalize();
        _readyTwap(t);

        address buyer = _actor("buyer");
        (uint256 cost,) = t.quoteOpen(1);
        uint256 start = 30 ether;
        vm.deal(buyer, start);
        vm.prank(buyer);
        t.mint{value: cost}(1);
        uint256 got = t.balanceOf(buyer);
        address[] memory back = new address[](2);
        back[0] = address(t);
        back[1] = address(wbnb);
        vm.startPrank(buyer);
        t.approve(address(router), got);
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(got, 0, back, buyer, block.timestamp);
        vm.stopPrank();
        assertLt(buyer.balance, start - cost / 20, "fee and tax are not free");
    }

    function test_openMintFeeIsNotReentrant() public {
        FeeReenter sink = new FeeReenter();
        dev = address(sink);
        FairToken t = _openReady(8, 1000);
        sink.set(t);
        address a = _actor("seed3");
        _mint(t, a, 4);
        uint256 soldBefore = t.sold();
        vm.warp(t.deadline());
        t.finalize();
        assertEq(t.sold(), soldBefore);
        assertGt(sink.tries(), 0);
        assertEq(MiniPair(t.pair()).balanceOf(address(t)), 0);
        assertGt(MiniPair(t.pair()).balanceOf(t.DEAD()), 0);

        _readyTwap(t);
        address b = _actor("open");
        (uint256 cost,) = t.quoteOpen(1);
        uint256 triesBefore = sink.tries();
        vm.deal(b, cost);
        vm.prank(b);
        t.mint{value: cost}(1);
        assertEq(t.sold(), soldBefore + 1);
        assertGt(sink.tries(), triesBefore);
        assertEq(MiniPair(t.pair()).balanceOf(address(t)), 0);
    }

    function _readyTwap(FairToken t) internal {
        vm.warp(block.timestamp + t.twapWindow() + 1);
        vm.roll(block.number + 1);
        t.poke();
    }

    function _openReady(uint256 cap, uint16 feeBps) internal returns (FairToken t) {
        FairToken.Params memory p = _params();
        p.hardCap = cap;
        p.softCap = cap / 2;
        p.maxPerWallet = cap;
        p.maxPerIdentity = 5;
        p.mintFeeBps = feeBps;
        p.twapWindow = 30 minutes;
        p.twapMaxDeviationBps = 1000;
        t = new FairToken(p);
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
        p.immediateUnlockBps = 1500;
        p.demandNum = 50;
        p.demandDen = 100;
        p.vestCliff = 7 days;
        p.vestLinear = 7 days;
        p.forfeitFullRate = 3 days;
        p.forfeitWindow = 14 days;
        p.swapThreshold = 1_000_000 ether;
        p.minUnit = 1e12;
    }

    function _actor(bytes32 id) internal returns (address a) {
        actorNonce++;
        a = makeAddr(string(abi.encodePacked("om", actorNonce)));
        ver.set(a, id);
        vm.deal(a, 1000 ether);
    }

    function _actorSame(address existing, bytes32 salt) internal returns (address a) {
        a = makeAddr(string(abi.encodePacked("same", salt, actorNonce)));
        ver.set(a, ver.idOf(existing));
        vm.deal(a, 1000 ether);
    }

    function _mint(FairToken t, address a, uint256 shares) internal {
        (uint256 cost,) = t.quote(shares);
        vm.prank(a);
        t.mint{value: cost}(shares);
    }

    function _vestShares(FairToken t, address a) internal view returns (uint256 shares) {
        (shares,,,,,,,,,,,) = t.accounts(a);
    }
}
