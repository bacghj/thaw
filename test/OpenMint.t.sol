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

    function test_postOpenAndMarketTokensDoNotForfeitBaseline() public {
        FairToken t = _openReady(8, 1000);
        address a = _actor("vested");
        _mint(t, a, 4);
        vm.warp(t.deadline());
        t.finalize();
        vm.prank(a);
        t.claim();
        uint256 baseline = t.balanceOf(a);
        (,,,,,,,,, uint256 forfeitedBefore,,) = t.accounts(a);

        _readyTwap(t);
        (uint256 cost,) = t.quoteOpen(1);
        vm.deal(a, a.balance + cost);
        vm.prank(a);
        t.mint{value: cost}(1);
        uint256 minted = t.tokensPerShare();
        assertEq(t.freeBalance(a), minted);
        vm.prank(a);
        t.transfer(makeAddr("mint-out"), minted);
        (,,,,,,,,, uint256 forfeitedAfterMint,,) = t.accounts(a);
        assertEq(forfeitedAfterMint, forfeitedBefore, "post-open mint does not forfeit");
        assertEq(t.balanceOf(a), baseline);

        uint256 beforeBuy = t.balanceOf(a);
        address[] memory path = new address[](2);
        path[0] = address(wbnb);
        path[1] = address(t);
        vm.prank(a);
        router.swapExactETHForTokens{value: 0.01 ether}(0, path, a, block.timestamp);
        uint256 bought = t.balanceOf(a) - beforeBuy;
        assertEq(t.freeBalance(a), bought);
        address[] memory back = new address[](2);
        back[0] = address(t);
        back[1] = address(wbnb);
        vm.startPrank(a);
        t.approve(address(router), bought);
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(bought, 0, back, a, block.timestamp);
        vm.stopPrank();
        (,,,,,,,,, uint256 forfeitedAfterSell,,) = t.accounts(a);
        assertEq(forfeitedAfterSell, forfeitedBefore, "market tokens do not forfeit");

        vm.prank(a);
        t.transfer(makeAddr("base-out"), baseline / 2);
        (,,,,,,,,, uint256 forfeitedBaseline,,) = t.accounts(a);
        assertGt(forfeitedBaseline, forfeitedBefore, "spending the baseline still forfeits");
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

    // ---------------------------------------------------------------------
    // TWAP ring buffer and overpayment refund
    // ---------------------------------------------------------------------

    function _openLive(uint256 cap) internal returns (FairToken t, address holder) {
        t = _openReady(cap, 1000);
        uint256 left = cap / 2;
        while (left > 0) {
            uint256 n = left > 5 ? 5 : left;
            holder = _actor(bytes32(uint256(0x9000) + left));
            _mint(t, holder, n);
            left -= n;
        }
        vm.warp(t.deadline());
        t.finalize();
    }

    /// Activity every 3-6 s for 4 hours (pokes, transfers, small buys and sells). After the first
    /// window the post-open mint must be priceable at every step, the quote must equal the charge,
    /// and periodic mints must succeed.
    function test_highFrequencyActivityNeverStarvesOpenMint() public {
        (FairToken t,) = _openLive(60);
        uint256 open = t.openTime();
        address trader = _actor("hf-trader");
        address[] memory buy = new address[](2);
        buy[0] = address(wbnb);
        buy[1] = address(t);
        address[] memory sell = new address[](2);
        sell[0] = address(t);
        sell[1] = address(wbnb);
        vm.prank(trader);
        t.approve(address(router), type(uint256).max);

        uint256 mints;
        uint256 checks;
        uint256 step;
        while (block.timestamp < open + 4 hours) {
            step++;
            vm.warp(block.timestamp + 3 + (step % 4));
            vm.roll(block.number + 1);
            if (step % 7 == 0) {
                vm.prank(trader);
                router.swapExactETHForTokens{value: 0.002 ether}(0, buy, trader, block.timestamp);
            } else if (step % 11 == 0 && t.balanceOf(trader) > 0) {
                uint256 bal = t.balanceOf(trader);
                vm.prank(trader);
                router.swapExactTokensForETHSupportingFeeOnTransferTokens(bal / 2, 0, sell, trader, block.timestamp);
            } else if (step % 2 == 0 && t.balanceOf(trader) > 1) {
                vm.prank(trader);
                t.transfer(makeAddr("hf-sink"), 1);
            } else {
                t.poke();
            }
            if (block.timestamp < open + t.twapWindow()) continue;
            (uint256 cost,) = t.quoteOpen(1);
            checks++;
            if (step % 300 == 0 && t.sold() < t.hardCap()) {
                address b = _actor(bytes32(uint256(0x5000) + step));
                uint256 before = b.balance;
                vm.prank(b);
                t.mint{value: cost + cost / 100}(1);
                assertEq(before - b.balance, cost, "charged exactly the same-block quote");
                mints++;
            }
        }
        assertGt(checks, 2000, "quoted at every step after the first window");
        assertGe(mints, 7, "mints kept succeeding for hours");
    }

    function test_openMintOverpaymentRefundedExactly() public {
        (FairToken t,) = _openLive(8);
        _readyTwap(t);
        address b = _actor("overpay");
        (uint256 cost,) = t.quoteOpen(2);
        uint256 before = b.balance;
        uint256 devBefore = dev.balance;
        uint256 pairWbnb = wbnb.balanceOf(t.pair());
        vm.prank(b);
        t.mint{value: cost + 1 ether}(2);
        assertEq(before - b.balance, cost, "excess refunded to the wei");
        assertEq(dev.balance - devBefore, cost * 1000 / 10_000, "fee on cost, not on msg.value");
        assertEq(wbnb.balanceOf(t.pair()) - pairWbnb, cost - cost * 1000 / 10_000, "LP gets cost minus fee");
        assertEq(address(t).balance, 0, "nothing stuck in the token");
        assertEq(t.balanceOf(b), 2 * t.tokensPerShare());
    }

    function test_openMintUnderpaymentReverts() public {
        (FairToken t,) = _openLive(8);
        _readyTwap(t);
        address b = _actor("underpay");
        (uint256 cost,) = t.quoteOpen(1);
        vm.prank(b);
        vm.expectRevert(abi.encodeWithSelector(FairToken.WrongPayment.selector, cost, cost - 1));
        t.mint{value: cost - 1}(1);
    }

    /// A buy that pushes spot ~10x, held for one block (3 s) and sold back, moves the
    /// 30-minute TWAP by about (10 - 1) * 3 / 1800 = 1.5%.
    function test_oneBlockSpikeMovesTwapMinimally() public {
        (FairToken t,) = _openLive(8);
        _readyTwap(t);
        uint256 base = t.twapPrice();
        uint256 spotBase = t.spotPrice();
        address atk = _actor("spike");
        vm.deal(atk, 1000 ether);
        address[] memory buy = new address[](2);
        buy[0] = address(wbnb);
        buy[1] = address(t);
        vm.prank(atk);
        router.swapExactETHForTokens{value: wbnb.balanceOf(t.pair()) * 22 / 10}(0, buy, atk, block.timestamp);
        assertGt(t.spotPrice(), spotBase * 9, "spot pushed about 10x");
        assertEq(t.twapPrice(), base, "same block: TWAP unchanged");

        vm.warp(block.timestamp + 3);
        vm.roll(block.number + 1);
        address[] memory sell = new address[](2);
        sell[0] = address(t);
        sell[1] = address(wbnb);
        uint256 got = t.balanceOf(atk);
        vm.startPrank(atk);
        t.approve(address(router), got);
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(got, 0, sell, atk, block.timestamp);
        vm.stopPrank();

        vm.warp(block.timestamp + 3);
        vm.roll(block.number + 1);
        uint256 after_ = t.twapPrice();
        uint256 moved = after_ > base ? after_ - base : base - after_;
        assertLt(moved * 10_000 / base, 200, "one-block 10x spike moves TWAP < 2%");
        (uint256 cost,) = t.quoteOpen(1);
        assertEq(cost, t.tokensPerShare() * after_ / PREC, "quote uses the TWAP");
    }

    /// The direction that would make minting cheaper: dumping the price for one block can lower
    /// the average by at most 3 s / 30 min (price cannot go below 0), here < 0.25%.
    function test_oneBlockDumpCannotCheapenMintMuch() public {
        (FairToken t, address holder) = _openLive(8);
        vm.prank(holder);
        t.claim();
        _readyTwap(t);
        uint256 base = t.twapPrice();
        uint256 spotBase = t.spotPrice();
        address[] memory sell = new address[](2);
        sell[0] = address(t);
        sell[1] = address(wbnb);
        uint256 bal = t.balanceOf(holder);
        vm.startPrank(holder);
        t.approve(address(router), bal);
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(bal, 0, sell, holder, block.timestamp);
        vm.stopPrank();
        assertLt(t.spotPrice(), spotBase, "spot dumped");
        vm.warp(block.timestamp + 3);
        vm.roll(block.number + 1);
        uint256 after_ = t.twapPrice();
        assertGe(after_ * 10_000, base * 9975, "TWAP drops < 0.25% from a one-block dump");
        // And a mint during the dump is refused by the spot-deviation guard, not cheapened.
        assertLt(t.spotPrice() * 10_000, after_ * 9000, "spot is >10% under the TWAP");
        address buyer = _actor("dump-buyer");
        (uint256 cost,) = t.quoteOpen(1);
        vm.prank(buyer);
        vm.expectRevert(FairToken.TwapDeviation.selector);
        t.mint{value: cost}(1);
    }

    /// The ring always keeps a checkpoint at least one window old once a window has passed.
    function test_twapRingKeepsAnOldEnoughCheckpoint() public {
        (FairToken t,) = _openLive(8);
        uint256 w = t.twapWindow();
        vm.expectRevert(FairToken.TwapNotReady.selector);
        t.twapPrice();
        for (uint256 i; i < 40; ++i) {
            vm.warp(block.timestamp + w / 2);
            vm.roll(block.number + 1);
            t.poke();
            if (block.timestamp >= t.openTime() + w) t.twapPrice();
        }
        // A long quiet gap still prices (the average covers the gap).
        vm.warp(block.timestamp + 10 * w);
        vm.roll(block.number + 1);
        t.twapPrice();
        t.poke();
        t.twapPrice();
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
