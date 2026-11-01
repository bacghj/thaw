// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {FairToken} from "../src/FairToken.sol";
import {MockAgentIdVerifier} from "./mocks/MockAgentIdVerifier.sol";
import {MiniFactory, MiniRouter, MiniWBNB} from "./mocks/MiniAmm.sol";
import {FairHandler} from "./handlers/FairHandler.sol";

contract FairInvariantTest is Test {
    FairToken internal token;
    MiniWBNB internal wbnb;
    FairHandler internal handler;

    function setUp() public {
        MockAgentIdVerifier ver = new MockAgentIdVerifier();
        wbnb = new MiniWBNB();
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
        p.hardCap = 16;
        p.softCap = 4;
        p.tier1Price = 0.004 ether;
        p.tier2Price = 0.005 ether;
        p.tier3Price = 0.006 ether;
        p.tier1Bps = 2500;
        p.tier2Bps = 5000;
        p.maxPerWallet = 4;
        p.maxPerIdentity = 4;
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
        token = new FairToken(p);

        address[] memory actors = new address[](4);
        for (uint256 i; i < 4; ++i) {
            actors[i] = makeAddr(string(abi.encodePacked("inv", i)));
            ver.set(actors[i], bytes32(uint256(i + 1)));
            vm.deal(actors[i], 500 ether);
            (uint256 cost,) = token.quote(4);
            vm.prank(actors[i]);
            token.mint{value: cost}(4);
        }
        token.finalize();

        handler = new FairHandler(token, router, wbnb, actors);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.claim.selector;
        selectors[1] = handler.poke.selector;
        selectors[2] = handler.warp.selector;
        selectors[3] = handler.transferOut.selector;
        selectors[4] = handler.buy.selector;
        selectors[5] = handler.sell.selector;
        selectors[6] = handler.skimPairToSelf.selector;
        selectors[7] = handler.syncPair.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_lockedAccounting() public view {
        assertEq(token.pool() + token.vestedOut() + token.burnedLocked() + token.earmark(), token.initialPool());
    }

    function invariant_tokenBalanceMatchesClaims() public view {
        uint256 owed = token.minterSupply() - token.burnedLocked() - token.claimedTotal();
        assertEq(token.balanceOf(address(token)), owed + token.taxDevReserve() + token.taxLpReserve());
        assertGe(token.balanceOf(address(token)), token.pool() + token.earmark() + token.taxDevReserve() + token.taxLpReserve());
    }

    function invariant_supply() public view {
        assertEq(token.totalSupply(), token.minterSupply() + token.lpMinted() - token.burnedLocked());
    }

    /// @notice Raised BNB left the launch contract at finalize. Trading can move LP BNB;
    ///         nothing in the handler can pull `raised` back out as an admin withdrawal.
    function invariant_raisedNotHeldByToken() public view {
        assertEq(address(token).balance, 0);
        assertGt(wbnb.balanceOf(token.pair()), 0);
    }

    function invariant_forfeitCurve() public view {
        uint256 open = token.openTime();
        uint256 full = token.forfeitFullRate();
        uint256 window = token.forfeitWindow();
        assertEq(token.forfeitRateAt(open), 1e18);
        assertEq(token.forfeitRateAt(open + full), 1e18);
        assertEq(token.forfeitRateAt(open + window), 0);
        uint256 span = window - full;
        uint256 mid = open + full + span / 2;
        assertEq(token.forfeitRateAt(mid), 0.5e18);
        assertGe(token.forfeitRateAt(open + full), token.forfeitRateAt(mid));
        assertGe(token.forfeitRateAt(mid), token.forfeitRateAt(open + window));
        assertGe(token.forfeitRateAt(open + full), token.forfeitRateAt(open + full + 1));
    }
}
