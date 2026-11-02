// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {FairToken} from "../src/FairToken.sol";
import {AgentIdVerifier, IHandleRegistry} from "../src/verifiers/AgentIdVerifier.sol";
import {IPancakeRouter, IPancakePair, IWBNB} from "../src/interfaces/IPancakeV2.sol";
import {DeployMainnet, ThawMainnetConfig, CheckMainnetDeployment} from "../script/DeployMainnet.s.sol";

interface IERC20Lite {
    function totalSupply() external view returns (uint256);
}

/// @notice Runs the real mainnet deploy script on a BSC mainnet fork and walks the launch paths
///         with the approved parameters. Nothing is broadcast. Agent IDs for synthetic minters are
///         mocked on the real registry address; the real `AgentIdVerifier` adapter is used.
contract DeployMainnetForkTest is Test, ThawMainnetConfig {
    FairToken t;
    AgentIdVerifier v;
    address[] minters;

    function setUp() public {
        vm.createSelectFork(vm.envOr("BSC_RPC_URL", string("https://bsc-dataseed.bnbchain.org")));
        assertEq(block.chainid, 56);
        DeployMainnet s = new DeployMainnet();
        (t, v) = s.run();
    }

    function _agent(uint256 i) internal returns (address a) {
        a = address(uint160(uint256(keccak256(abi.encode("thaw-fork-minter", i)))));
        string memory handle = string.concat("thawfork", vm.toString(i));
        vm.mockCall(AGENT_REGISTRY, abi.encodeCall(IHandleRegistry.handleOf, (a)), abi.encode(handle));
        vm.mockCall(AGENT_REGISTRY, abi.encodeCall(IHandleRegistry.ownerOfHandle, (handle)), abi.encode(a));
        vm.deal(a, 1 ether);
    }

    function _subscribe(uint256 nIds) internal {
        for (uint256 i; i < nIds; ++i) {
            address a = _agent(i);
            (uint256 cost,) = t.quote(5);
            vm.prank(a);
            t.mint{value: cost}(5);
            minters.push(a);
        }
    }

    function _checkOpen(uint256 sold, uint256 raisedWei, uint256 devBefore) internal view {
        address pair = t.pair();
        assertTrue(pair != address(0), "pair");
        assertEq(t.sold(), sold, "sold");
        assertEq(t.raised(), raisedWei, "raised");
        assertEq(DEV_WALLET.balance - devBefore, raisedWei / 10, "10% to dev");
        assertEq(IWBNB(WBNB).balanceOf(pair), raisedWei - raisedWei / 10, "90% to LP");
        assertEq(address(t).balance, 0, "no BNB left in token");
        // LP: everything except Pancake's MINIMUM_LIQUIDITY (1000 wei to 0x0) sits at DEAD.
        uint256 lpSupply = IERC20Lite(pair).totalSupply();
        assertEq(IPancakePair(pair).balanceOf(DEAD_ADDR), lpSupply - 1000, "LP to DEAD");
        assertEq(IPancakePair(pair).balanceOf(address(t)), 0, "token holds no LP");
        assertEq(IPancakePair(pair).balanceOf(DEPLOYER), 0, "deployer holds no LP");
        assertEq(IPancakePair(pair).balanceOf(DEV_WALLET), 0, "dev holds no LP");
        // Open price = 1.5 x average mint cost (within rounding).
        uint256 tokensInPair = t.balanceOf(pair);
        uint256 w = IWBNB(WBNB).balanceOf(pair);
        assertApproxEqRel(w * t.minterSupply() * 2, tokensInPair * raisedWei * 3, 1e12, "open price");
    }

    address constant DEAD_ADDR = 0x000000000000000000000000000000000000dEaD;

    function test_scriptReadback() public view {
        // `run()` already executed `checkDeployed`; re-check here so a failure names the test.
        checkDeployed(t, v, t.deadline() - MINT_DURATION);
        assertEq(t.deadline() - MINT_DURATION, block.timestamp);
        (bool ok, bytes32 id) = v.verify(0x5E3fBbc8D260a63C9fe19CbBb0A9d5792C3375eA);
        assertTrue(ok);
        assertEq(id, keccak256("binance"));
    }

    function test_postDeployCheckScript() public {
        CheckMainnetDeployment c = new CheckMainnetDeployment();
        c.run(address(t));
        // After the first mint the fresh-state check must fail (it is a just-deployed check only).
        address a = _agent(0);
        (uint256 cost,) = t.quote(1);
        vm.prank(a);
        t.mint{value: cost}(1);
        vm.expectRevert();
        c.run(address(t));
    }

    function test_refusesPrivateKeyEnv() public {
        vm.setEnv("PRIVATE_KEY", "0x01");
        DeployMainnet s = new DeployMainnet();
        vm.expectRevert(abi.encodeWithSelector(ThawMainnetConfig.PrivateKeyEnvForbidden.selector, "PRIVATE_KEY"));
        s.run();
        vm.setEnv("PRIVATE_KEY", "");
    }

    function test_refusesOtherChain() public {
        vm.chainId(97);
        DeployMainnet s = new DeployMainnet();
        vm.expectRevert(abi.encodeWithSelector(ThawMainnetConfig.WrongChain.selector, uint256(97)));
        s.run();
    }

    function test_softCapReached_opensWithLpAtDead_thenTwapMint() public {
        _subscribe(SOFT_CAP / 5); // 400 IDs x 5 = 2,000 shares, all tier 1
        assertEq(t.sold(), SOFT_CAP);
        vm.expectRevert();
        t.finalize(); // window still open, cap not full
        vm.warp(t.deadline());
        uint256 devBefore = DEV_WALLET.balance;
        t.finalize();
        _checkOpen(SOFT_CAP, SOFT_CAP * TIER1_PRICE, devBefore);
        assertEq(t.raised(), 8 ether);
        console2.log("softcap LP WBNB", IWBNB(WBNB).balanceOf(t.pair()));

        // Claim 15% immediately.
        vm.prank(minters[0]);
        t.claim();
        assertEq(t.balanceOf(minters[0]), 5 * TOKENS_PER_SHARE * IMMEDIATE_BPS / 10_000);

        // Post-open mint: blocked before one TWAP window, allowed after, at TWAP, LP to DEAD.
        address late = _agent(100_000);
        vm.deal(late, 10 ether);
        vm.prank(late);
        vm.expectRevert();
        t.mint{value: 1 ether}(1);
        vm.warp(block.timestamp + TWAP_WINDOW + 1);
        vm.roll(block.number + 1);
        t.poke();
        (uint256 cost,) = t.quoteOpen(5);
        uint256 lpBefore = IPancakePair(t.pair()).balanceOf(DEAD_ADDR);
        vm.prank(late);
        t.mint{value: cost + cost / 100}(5);
        assertEq(t.balanceOf(late), 5 * TOKENS_PER_SHARE);
        assertEq(late.balance, 10 ether - cost, "overpay refunded");
        assertGt(IPancakePair(t.pair()).balanceOf(DEAD_ADDR), lpBefore, "post-open LP to DEAD");
        // Lifetime cap: 6th share for the same ID is refused.
        vm.prank(late);
        vm.expectRevert();
        t.mint{value: 1 ether}(1);
    }

    function test_belowSoftCap_fullRefund() public {
        _subscribe(SOFT_CAP / 5 - 1); // 1,995 shares
        vm.warp(t.deadline());
        vm.expectRevert();
        t.finalize();
        t.triggerRefund();
        for (uint256 i; i < 3; ++i) {
            address a = minters[i];
            uint256 before = a.balance;
            vm.prank(a);
            t.refund();
            assertEq(a.balance - before, 5 * TIER1_PRICE, "full refund");
        }
    }

    function test_hardCap_sixThousandIds_finalizeGas() public {
        _subscribe(HARD_CAP / 5); // 6,000 IDs
        assertEq(t.sold(), HARD_CAP);
        assertEq(t.raised(), 150 ether);
        uint256 devBefore = DEV_WALLET.balance;
        uint256 g = gasleft();
        t.finalize(); // cap full: no need to wait for the deadline
        console2.log("finalize gas @6000 holders", g - gasleft());
        _checkOpen(HARD_CAP, 150 ether, devBefore);
        address late = _agent(200_000);
        vm.prank(late);
        vm.expectRevert();
        t.mint{value: 1 ether}(1);
    }
}
