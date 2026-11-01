// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AgentIdVerifier} from "../src/verifiers/AgentIdVerifier.sol";
import {MockHandleRegistry} from "../src/testnet/MockHandleRegistry.sol";

contract MockHandleRegistryTest is Test {
    MockHandleRegistry internal reg;
    AgentIdVerifier internal verifier;

    function setUp() public {
        reg = new MockHandleRegistry();
        verifier = new AgentIdVerifier(address(reg));
    }

    function test_RegisterMatchesSpaceIdShape() public {
        address wallet = makeAddr("wallet");
        reg.register(wallet, "alpha");

        assertEq(reg.handleOf(wallet), "alpha");
        assertEq(reg.ownerOfHandle("alpha"), wallet);

        (bool ok, bytes32 id) = verifier.verify(wallet);
        assertTrue(ok);
        assertEq(id, keccak256("alpha"));

        (bool no, bytes32 empty) = verifier.verify(makeAddr("other"));
        assertFalse(no);
        assertEq(empty, bytes32(0));
    }

    function test_StrangerCannotRegister() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(MockHandleRegistry.NotOwner.selector);
        reg.register(makeAddr("wallet"), "beta");
    }
}
