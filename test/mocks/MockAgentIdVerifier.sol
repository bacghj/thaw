// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAgentIdVerifier} from "../../src/interfaces/IAgentIdVerifier.sol";

/// @notice Test double. `identityKey == 0` means "no Agent ID".
contract MockAgentIdVerifier is IAgentIdVerifier {
    mapping(address => bytes32) public idOf;

    function set(address account, bytes32 id) external {
        idOf[account] = id;
    }

    function verify(address account) external view returns (bool ok, bytes32 identityKey) {
        identityKey = idOf[account];
        ok = identityKey != bytes32(0);
    }
}
