// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {FairToken} from "../src/FairToken.sol";
import {FairTokenExt} from "../src/FairTokenExt.sol";
import {Forbidden} from "../src/FairTokenBase.sol";
import {MockAgentIdVerifier} from "./mocks/MockAgentIdVerifier.sol";
import {MiniFactory, MiniRouter, MiniWBNB} from "./mocks/MiniAmm.sol";

/// @notice Deployment-size guard: forge tests do not enforce EIP-170 / EIP-3860, so assert them here.
contract SizeTest is Test {
    uint256 constant EIP170_RUNTIME_LIMIT = 24_576;
    uint256 constant EIP3860_INITCODE_LIMIT = 49_152;

    FairToken internal t;
    FairToken.Params internal params;

    function setUp() public {
        MiniWBNB wbnb = new MiniWBNB();
        MiniFactory factory = new MiniFactory();
        MiniRouter router = new MiniRouter(address(factory), address(wbnb));
        FairToken.Params memory p;
        p.name = "Fair Mint Token";
        p.symbol = "FMT";
        p.verifier = address(new MockAgentIdVerifier());
        p.devWallet = makeAddr("dev");
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
        params = p;
        t = new FairToken(p);
    }

    function test_runtimeSizeUnderEip170() public view {
        uint256 tokenSize = address(t).code.length;
        uint256 extSize = t.extension().code.length;
        console2.log("FairToken runtime", tokenSize);
        console2.log("FairTokenExt runtime", extSize);
        assertLt(tokenSize, EIP170_RUNTIME_LIMIT, "FairToken runtime >= 24576");
        assertLt(extSize, EIP170_RUNTIME_LIMIT, "FairTokenExt runtime >= 24576");
    }

    /// @dev The deploy transaction's initcode is creation code plus ABI-encoded constructor args.
    function test_initcodeUnderEip3860() public view {
        uint256 initcode = abi.encodePacked(type(FairToken).creationCode, abi.encode(params)).length;
        console2.log("FairToken deploy initcode (with args)", initcode);
        assertLt(initcode, EIP3860_INITCODE_LIMIT, "FairToken initcode >= 49152");
    }

    function test_extensionOnlyViaDelegatecall() public {
        FairTokenExt ext = FairTokenExt(t.extension());
        vm.expectRevert(Forbidden.selector);
        ext.finalize();
        vm.expectRevert(Forbidden.selector);
        ext.mintOpen(1, bytes32(0));
        vm.expectRevert(Forbidden.selector);
        ext.noteSale(address(this), 1);
        vm.expectRevert(Forbidden.selector);
        ext.flushEarmarkAll();
    }
}
