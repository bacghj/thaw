// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAgentIdVerifier} from "../interfaces/IAgentIdVerifier.sol";

/// @notice Read interface of the SPACE ID Agent ID registry used by Binance Agentic Wallets.
///         Mainnet (chain 56): 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F
///         Collection name "SPACE ID Agent ID", symbol "AI". Soulbound ERC-721.
///         tokenId == uint256(keccak256(bytes(handle))) — checked on-chain for handle "binance".
interface IHandleRegistry {
    function handleOf(address owner) external view returns (string memory);
    function ownerOfHandle(string calldata handle) external view returns (address);
}

/// @title AgentIdVerifier
/// @notice Adapter from `IHandleRegistry` to `IAgentIdVerifier`.
///         Identity key is `keccak256(handle)`, so the per-ID cap follows the handle, not the wallet.
///         Fails closed: empty handle, forward/reverse mismatch, or a zero key all reject.
/// @dev The registry itself has an admin/signer that can issue IDs. This adapter cannot change that.
///      Handles are soulbound today (`transferFrom` reverts with `Soulbound`), so one wallet holds one ID.
contract AgentIdVerifier is IAgentIdVerifier {
    address public immutable registry;

    error ZeroAddress();

    constructor(address registry_) {
        if (registry_ == address(0)) revert ZeroAddress();
        registry = registry_;
    }

    function verify(address account) external view returns (bool ok, bytes32 identityKey) {
        string memory handle = IHandleRegistry(registry).handleOf(account);
        if (bytes(handle).length == 0) return (false, bytes32(0));
        if (IHandleRegistry(registry).ownerOfHandle(handle) != account) return (false, bytes32(0));
        identityKey = keccak256(bytes(handle));
        if (identityKey == bytes32(0)) return (false, bytes32(0));
        ok = true;
    }
}
