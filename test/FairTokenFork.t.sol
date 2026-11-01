// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {FairToken} from "../src/FairToken.sol";
import {AgentIdVerifier} from "../src/verifiers/AgentIdVerifier.sol";
import {MockAgentIdVerifier} from "./mocks/MockAgentIdVerifier.sol";
import {IPancakeRouter, IPancakePair, IWBNB} from "../src/interfaces/IPancakeV2.sol";

/// @notice Mainnet-fork coverage against live PancakeSwap V2. No transaction is broadcast.
contract FairTokenForkTest is Test {
    address constant ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant REGISTRY = 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F;
    address constant BINANCE_ID = 0x5E3fBbc8D260a63C9fe19CbBb0A9d5792C3375eA;

    function setUp() public {
        string memory url = vm.envOr("BSC_RPC_URL", string("https://bsc-dataseed.bnbchain.org"));
        vm.createSelectFork(url);
        assertEq(block.chainid, 56);
        assertEq(IPancakeRouter(ROUTER).factory(), FACTORY);
        assertEq(IPancakeRouter(ROUTER).WETH(), WBNB);
    }

    function _params(address verifier, address dev) internal view returns (FairToken.Params memory p) {
        p.name = "Fair Mint Token";
        p.symbol = "FMT";
        p.verifier = verifier;
        p.devWallet = dev;
        p.router = ROUTER;
        p.factory = FACTORY;
        p.wbnb = WBNB;
        p.hardCap = 8;
        p.softCap = 2;
        p.tier1Price = 0.004 ether;
        p.tier2Price = 0.005 ether;
        p.tier3Price = 0.006 ether;
        p.tier1Bps = 2500;
        p.tier2Bps = 5000;
        p.maxPerWallet = 8;
        p.maxPerIdentity = 8;
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
    }

    function test_fork_realAgentIdGate() public {
        AgentIdVerifier adapter = new AgentIdVerifier(REGISTRY);
        (bool ok, bytes32 key) = adapter.verify(BINANCE_ID);
        assertTrue(ok);
        assertEq(key, keccak256("binance"));
        assertEq(BINANCE_ID.code.length, 0);

        (bool no,) = adapter.verify(address(0xBEEF));
        assertFalse(no);

        FairToken t = new FairToken(_params(address(adapter), makeAddr("dev")));
        vm.deal(BINANCE_ID, 1 ether);
        (uint256 cost,) = t.quote(1);
        vm.prank(BINANCE_ID);
        t.mint{value: cost}(1);
        (uint256 mintedShares,,,,,,,,,,,) = t.accounts(BINANCE_ID);
        assertEq(mintedShares, 1);

        address stranger = makeAddr("stranger");
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(FairToken.NotAgent.selector, stranger));
        t.mint{value: cost}(1);
    }

    function test_fork_fullFlowAndDonation() public {
        MockAgentIdVerifier ver = new MockAgentIdVerifier();
        address dev = makeAddr("dev");
        FairToken t = new FairToken(_params(address(ver), dev));

        // Pre-create the pair and sync a WBNB donation. Finalize must still hit the target price.
        address pair = IPancakeRouter(ROUTER).factory() == FACTORY
            ? _createOrGet(address(t))
            : address(0);
        address donor = makeAddr("donor");
        vm.deal(donor, 2 ether);
        vm.startPrank(donor);
        IWBNB(WBNB).deposit{value: 1 ether}();
        require(IWBNB(WBNB).transfer(pair, 1 ether), "don");
        vm.stopPrank();
        IPancakePair(pair).sync();

        address a = makeAddr("minter");
        ver.set(a, bytes32("a"));
        vm.deal(a, 10 ether);
        uint256 cap = t.hardCap();
        (uint256 cost,) = t.quote(cap);
        vm.prank(a);
        t.mint{value: cost}(cap);
        uint256 gasBefore = gasleft();
        t.finalize();
        console2.log("finalize-gas", gasBefore - gasleft());

        assertEq(t.pair(), pair);
        uint256 w = IWBNB(WBNB).balanceOf(pair);
        uint256 tokens = t.balanceOf(pair);
        assertApproxEqAbs(
            w * t.minterSupply() * t.premiumDen(),
            tokens * t.raised() * t.premiumNum(),
            t.raised() * t.premiumNum()
        );
        assertGt(IPancakePair(pair).balanceOf(t.DEAD()), 0);
        assertEq(address(t).balance, 0);

        vm.prank(a);
        t.claim();
        uint256 liquid = t.balanceOf(a);

        address buyer = makeAddr("buyer");
        vm.deal(buyer, 5 ether);
        address[] memory path = new address[](2);
        path[0] = WBNB;
        path[1] = address(t);
        vm.prank(buyer);
        IPancakeRouter(ROUTER).swapExactETHForTokens{value: 0.2 ether}(0, path, buyer, block.timestamp);
        uint256 bought = t.balanceOf(buyer);
        uint256 tax = t.taxDevReserve() + t.taxLpReserve();
        assertEq(tax, (bought + tax) * 300 / 10_000);

        address[] memory back = new address[](2);
        back[0] = address(t);
        back[1] = WBNB;
        vm.startPrank(buyer);
        t.approve(ROUTER, bought / 2);
        IPancakeRouter(ROUTER).swapExactTokensForETHSupportingFeeOnTransferTokens(bought / 2, 0, back, buyer, block.timestamp);
        vm.stopPrank();
        assertGt(dev.balance, 0);

        // Forfeit at day 3 (still inside the 100% window, before the vest cliff).
        (uint256 locked,,,) = t.unlockState(a);
        vm.warp(t.openTime() + 3 days);
        t.poke();
        vm.prank(a);
        t.transfer(makeAddr("sink"), liquid);
        (uint256 lockedAfter,,,) = t.unlockState(a);
        assertEq(lockedAfter, 0);
        (,,,,,,,,, uint256 forfeitedOut,,) = t.accounts(a);
        assertEq(forfeitedOut, locked);

        vm.warp(t.openTime() + 14 days);
        t.poke();
        assertEq(t.forfeitRateAt(block.timestamp), 0);
        (uint256 lockedEnd,, uint256 claimable,) = t.unlockState(buyer);
        // buyer is not a minter
        assertEq(lockedEnd, 0);
        assertEq(claimable, 0);
        assertEq(t.pool() + t.vestedOut() + t.burnedLocked() + t.earmark(), t.initialPool());
    }

    function _createOrGet(address token) internal returns (address pair) {
        (bool ok, bytes memory data) =
            FACTORY.call(abi.encodeWithSignature("getPair(address,address)", token, WBNB));
        require(ok, "getPair");
        pair = abi.decode(data, (address));
        if (pair == address(0)) {
            (ok, data) = FACTORY.call(abi.encodeWithSignature("createPair(address,address)", token, WBNB));
            require(ok, "createPair");
            pair = abi.decode(data, (address));
        }
    }
}
