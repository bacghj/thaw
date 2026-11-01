// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Gate for the mint. `identityKey` is stable for one Agent ID across wallets.
///         Return `(false, 0)` when `account` holds no Agent ID.
interface IAgentIdVerifier {
    function verify(address account) external view returns (bool ok, bytes32 identityKey);
}
