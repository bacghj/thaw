// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FairTokenBase, InvalidParams} from "./FairTokenBase.sol";

/// @title FairTokenParams
/// @notice Constructor argument checks for `FairToken`, moved verbatim out of the token so its
///         initcode fits EIP-3860. Stateless, pure, no storage; deployed once and linked.
library FairTokenParams {
    // Same values as `FairTokenBase.BPS` / `FairTokenBase.PREC`.
    uint256 private constant BPS = 10_000;
    uint256 private constant PREC = 1e18;

    /// @dev Reverts `InvalidParams(what)` exactly as the token constructor did before.
    function validate(FairTokenBase.Params memory p) external pure {
        if (p.verifier == address(0) || p.devWallet == address(0) || p.router == address(0) || p.factory == address(0) || p.wbnb == address(0)) {
            revert InvalidParams("address");
        }
        if (p.devWallet == p.router || p.devWallet == p.factory || p.devWallet == p.wbnb) revert InvalidParams("dev");
        if (p.softCap == 0 || p.softCap > p.hardCap) revert InvalidParams("cap");
        if (p.tier1Price == 0 || p.tier2Price == 0 || p.tier3Price == 0) revert InvalidParams("price");
        if (p.tier1Bps == 0 || p.tier2Bps == 0 || uint256(p.tier1Bps) + uint256(p.tier2Bps) >= BPS) revert InvalidParams("tiers");
        if (p.maxPerWallet == 0 || p.maxPerIdentity == 0) revert InvalidParams("wallet cap");
        if (p.mintDuration == 0) revert InvalidParams("duration");
        if (p.tokensPerShare == 0 || p.tokensPerShare % BPS != 0) revert InvalidParams("tokensPerShare");
        if (p.immediateUnlockBps == 0 || p.immediateUnlockBps >= BPS) revert InvalidParams("immediate");
        if (p.premiumDen == 0 || p.premiumNum <= p.premiumDen) revert InvalidParams("premium");
        if ((p.tokensPerShare * p.premiumDen) % p.premiumNum != 0) revert InvalidParams("premium divisibility");
        if (p.demandDen == 0 || p.demandNum == 0) revert InvalidParams("demand");
        if (p.vestCliff == 0 || p.vestLinear == 0) revert InvalidParams("vest");
        if (p.forfeitFullRate == 0 || p.forfeitWindow <= p.forfeitFullRate) revert InvalidParams("forfeit window");
        if (p.swapThreshold == 0 || p.minUnit == 0) revert InvalidParams("threshold");
        if (p.mintFeeBps >= BPS) revert InvalidParams("mint fee");

        uint256 maxSupply = p.hardCap * p.tokensPerShare;
        if (p.hardCap != 0 && maxSupply / p.tokensPerShare != p.hardCap) revert InvalidParams("supply overflow");
        if (maxSupply > type(uint256).max / PREC) revert InvalidParams("supply scale");
        if (p.premiumNum != 0 && maxSupply > type(uint256).max / p.premiumNum) revert InvalidParams("premium scale");

        uint256 locked = p.tokensPerShare * (BPS - p.immediateUnlockBps) / BPS;
        uint256 immediate = p.tokensPerShare - locked;
        if (locked == 0 || immediate == 0) revert InvalidParams("split");

        uint256 t1 = p.hardCap * p.tier1Bps / BPS;
        uint256 t2 = t1 + p.hardCap * p.tier2Bps / BPS;
        if (t1 == 0 || t2 <= t1 || t2 >= p.hardCap) revert InvalidParams("tier bounds");
    }
}
