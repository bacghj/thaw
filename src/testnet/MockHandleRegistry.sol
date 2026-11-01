// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHandleRegistry} from "../verifiers/AgentIdVerifier.sol";

/// @title MockHandleRegistry
/// @notice Testnet stand-in for the SPACE ID Agent ID registry (`IHandleRegistry`).
///         That registry is deployed on BSC mainnet only. This contract is not part of the
///         production token. `FairToken` still reads identities through `AgentIdVerifier`.
/// @dev The deployer is the only account that can register handles. There is no other admin
///      on the token. Do not point a mainnet `FairToken` at this mock.
contract MockHandleRegistry is IHandleRegistry {
    address public immutable owner;

    mapping(address => string) private _handleOf;
    mapping(string => address) private _ownerOfHandle;

    error NotOwner();
    error InvalidRegistration();

    event Registered(address indexed account, string handle);

    constructor() {
        owner = msg.sender;
    }

    function register(address account, string calldata handle) external {
        if (msg.sender != owner) revert NotOwner();
        if (account == address(0) || bytes(handle).length == 0) revert InvalidRegistration();

        string memory previous = _handleOf[account];
        if (bytes(previous).length != 0) {
            delete _ownerOfHandle[previous];
        }
        address previousOwner = _ownerOfHandle[handle];
        if (previousOwner != address(0) && previousOwner != account) {
            delete _handleOf[previousOwner];
        }

        _handleOf[account] = handle;
        _ownerOfHandle[handle] = account;
        emit Registered(account, handle);
    }

    function handleOf(address account) external view returns (string memory) {
        return _handleOf[account];
    }

    function ownerOfHandle(string calldata handle) external view returns (address) {
        return _ownerOfHandle[handle];
    }
}
