// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {FairToken} from "../../src/FairToken.sol";
import {MiniPair, MiniRouter, MiniWBNB} from "../mocks/MiniAmm.sol";
import {EntitlementOracle} from "../EntitlementOracle.sol";

contract FairHandler is CommonBase, StdCheats, StdUtils {
    FairToken public token;
    MiniRouter public router;
    MiniWBNB public wbnb;
    EntitlementOracle public oracle;
    address[] public actors;

    modifier tracked() {
        _;
        oracle.sync();
    }

    constructor(FairToken token_, MiniRouter router_, MiniWBNB wbnb_, address[] memory actors_) {
        token = token_;
        router = router_;
        wbnb = wbnb_;
        for (uint256 i; i < actors_.length; ++i) actors.push(actors_[i]);
        oracle = new EntitlementOracle(token_, actors_);
    }

    function claim(uint256 i) external tracked {
        address a = actors[i % actors.length];
        vm.prank(a);
        token.claim();
    }

    function poke() external tracked {
        token.poke();
    }

    function warp(uint256 dt) external tracked {
        dt = bound(dt, 1 hours, 3 days);
        vm.warp(block.timestamp + dt);
        vm.roll(block.number + 1);
        if (block.timestamp >= token.openTime() + token.forfeitWindow()) token.poke();
    }

    function closeVest() external tracked {
        uint256 end = token.openTime() + token.forfeitWindow();
        if (block.timestamp < end) vm.warp(end);
        vm.roll(block.number + 1);
        token.poke();
    }

    function transferOut(uint256 i, uint256 pct) external tracked {
        address a = actors[i % actors.length];
        uint256 bal = token.balanceOf(a);
        if (bal == 0) return;
        pct = bound(pct, 1, 100);
        uint256 amt = bal * pct / 100;
        if (amt == 0) return;
        vm.prank(a);
        token.transfer(actors[(i + 1) % actors.length], amt);
    }

    function buy(uint256 i, uint256 pay) external tracked {
        pay = bound(pay, 0.01 ether, 0.05 ether);
        address a = actors[i % actors.length];
        address[] memory path = new address[](2);
        path[0] = address(wbnb);
        path[1] = address(token);
        vm.prank(a);
        router.swapExactETHForTokens{value: pay}(0, path, a, block.timestamp);
    }

    function sell(uint256 i, uint256 pct) external tracked {
        address a = actors[i % actors.length];
        uint256 bal = token.balanceOf(a);
        if (bal < 1e15) return;
        pct = bound(pct, 1, 40);
        uint256 amt = bal * pct / 100;
        if (amt == 0) return;
        vm.startPrank(a);
        token.approve(address(router), amt);
        address[] memory path = new address[](2);
        path[0] = address(token);
        path[1] = address(wbnb);
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(amt, 0, path, a, block.timestamp);
        vm.stopPrank();
    }

    function skimPairToSelf() external tracked {
        MiniPair(token.pair()).skim(token.pair());
    }

    function syncPair() external tracked {
        MiniPair(token.pair()).sync();
    }
}
