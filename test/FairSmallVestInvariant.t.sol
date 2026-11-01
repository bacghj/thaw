// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {FairToken} from "../src/FairToken.sol";
import {MockAgentIdVerifier} from "./mocks/MockAgentIdVerifier.sol";
import {MiniFactory, MiniPair, MiniRouter, MiniWBNB} from "./mocks/MiniAmm.sol";

contract SmallVestHandler is CommonBase, StdCheats, StdUtils {
    FairToken public token;
    MiniWBNB public wbnb;
    address[] public actors;

    constructor(FairToken token_, MiniWBNB wbnb_, address[] memory actors_) {
        token = token_;
        wbnb = wbnb_;
        for (uint256 i; i < actors_.length; ++i) actors.push(actors_[i]);
    }

    function actorLength() external view returns (uint256) {
        return actors.length;
    }

    function poke() external {
        token.poke();
    }

    function claim(uint256 i) external {
        address a = actors[i % actors.length];
        vm.prank(a);
        token.claim();
    }

    function tinyBuy(uint256 amountOut) external {
        amountOut = bound(amountOut, 1, 40);
        address pair = token.pair();
        MiniPair p = MiniPair(pair);
        (uint112 r0, uint112 r1,) = p.getReserves();
        bool token0 = p.token0() == address(token);
        uint256 reserveOut = token0 ? uint256(r0) : uint256(r1);
        if (amountOut == 0 || amountOut >= reserveOut) return;
        wbnb.deposit{value: 0.01 ether}();
        wbnb.transfer(pair, 0.01 ether);
        p.swap(token0 ? amountOut : 0, token0 ? 0 : amountOut, address(this), "");
    }
}

/// @notice Small-supply, multi-holder, multi-round demand. Vest credits cannot exceed vestedOut.
contract FairSmallVestInvariantTest is Test {
    FairToken internal token;
    SmallVestHandler internal handler;

    function setUp() public {
        MockAgentIdVerifier ver = new MockAgentIdVerifier();
        MiniWBNB wbnb = new MiniWBNB();
        MiniFactory factory = new MiniFactory();
        MiniRouter router = new MiniRouter(address(factory), address(wbnb));

        FairToken.Params memory p;
        p.name = "Small";
        p.symbol = "S";
        p.verifier = address(ver);
        p.devWallet = makeAddr("dev");
        p.router = address(router);
        p.factory = address(factory);
        p.wbnb = address(wbnb);
        p.hardCap = 8;
        p.softCap = 4;
        p.tier1Price = 0.0001 ether;
        p.tier2Price = 0.00012 ether;
        p.tier3Price = 0.00015 ether;
        p.tier1Bps = 2500;
        p.tier2Bps = 5000;
        p.maxPerWallet = 2;
        p.maxPerIdentity = 2;
        p.mintDuration = 1 hours;
        p.tokensPerShare = 30_000;
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
        token = new FairToken(p);

        address[] memory actors = new address[](4);
        for (uint256 i; i < 4; ++i) {
            actors[i] = makeAddr(string(abi.encodePacked("small", i)));
            ver.set(actors[i], bytes32(i + 1));
            vm.deal(actors[i], 1 ether);
            (uint256 cost,) = token.quote(2);
            vm.prank(actors[i]);
            token.mint{value: cost}(2);
        }
        token.finalize();

        handler = new SmallVestHandler(token, wbnb, actors);
        vm.deal(address(handler), 100 ether);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = handler.poke.selector;
        selectors[1] = handler.claim.selector;
        selectors[2] = handler.tinyBuy.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_vestClaimsWithinReleased() public view {
        uint256 sum;
        uint256 n = handler.actorLength();
        for (uint256 i; i < n; ++i) {
            address a = handler.actors(i);
            (uint256 shares,, uint256 points,,,,,,,,, bool materialized) = token.accounts(a);
            uint256 pts = materialized ? points : shares * token.lockedPerShare();
            sum += pts * token.accVest() / 1e18;
        }
        assertLe(sum, token.vestedOut());
        assertGe(
            token.balanceOf(address(token)),
            token.pool() + token.earmark() + token.taxDevReserve() + token.taxLpReserve()
        );
    }
}
