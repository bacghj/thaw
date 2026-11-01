// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FairTokenBase, FinalizeNotReady, AlreadyFinalized, RefundFailed, Forbidden} from "./FairTokenBase.sol";
import {IPancakeFactory, IPancakePair, IWBNB} from "./interfaces/IPancakeV2.sol";
import {FullMath} from "./FullMath.sol";

/// @title FairTokenExt
/// @notice Logic moved out of `FairToken` to keep it under the 24,576-byte EIP-170 limit.
///         Deployed once by the `FairToken` constructor with identical `Params`, so every
///         immutable matches. Each entrypoint runs only under DELEGATECALL from that token
///         (`address(this) == token`); a direct call reverts with `Forbidden`. It has no storage
///         of its own that matters, no owner, and no function that moves value except the
///         bodies copied unchanged from `FairToken`.
contract FairTokenExt is FairTokenBase {
    /// @dev The `FairToken` that created this extension.
    address private immutable token;

    constructor(Params memory p) FairTokenBase(p) {
        token = msg.sender;
    }

    /// @dev The creating `FairToken` already ran every check on the same `p`.
    function _validateParams(Params memory) internal pure override {}

    modifier onlyToken() {
        if (address(this) != token) revert Forbidden();
        _;
    }

    /// @dev Body of `FairToken.finalize`. The caller holds the reentrancy lock.
    function finalize() external payable onlyToken {
        if (launched || refundMode) revert AlreadyFinalized();
        bool capFilled = sold == hardCap;
        bool windowOk = block.timestamp >= deadline && sold >= softCap;
        if (!capFilled && !windowOk) revert FinalizeNotReady();
        if (raised == 0 || sold == 0) revert FinalizeNotReady();

        inFinalize = true;
        launched = true;
        openTime = block.timestamp;
        lastCommitBlock = block.number;

        minterSupply = sold * tokensPerShare;
        initialPool = sold * lockedPerShare;
        pool = initialPool;
        // Few holders: points are locked wei and a bounded walk matches the reference model.
        // Many holders: magnified raw and global indices, O(1) per transfer.
        exactMode = activeHolders <= EXACT_MAX;
        totalPoints = exactMode ? initialPool : initialPool * RAW;
        vestScale = PREC;
        // 1e36, not 1e18: a 1-ulp factor error must stay far below 1 raw unit.
        accForfeit = PREC * PREC;

        address p = IPancakeFactory(factory).getPair(address(this), wbnb);
        if (p == address(0)) p = IPancakeFactory(factory).createPair(address(this), wbnb);
        pair = p;

        // Drop donations that were not synced. Synced donations stay in reserves and are priced in below.
        IPancakePair(p).skim(DEAD);

        uint256 t0 = balanceOf[p];
        uint256 w0 = IWBNB(wbnb).balanceOf(p);
        uint256 fee = raised * mintFeeBps / BPS;
        uint256 wAdd = raised - fee;
        if (wAdd == 0) revert FinalizeNotReady();
        // Price target uses the full raise, not the 90% that is paired, so the open
        // is still premium times the average mint cost.
        uint256 finalT = FullMath.mulDiv(w0 + wAdd, minterSupply * premiumDen, raised * premiumNum);
        uint256 tAdd = t0 >= finalT ? 0 : finalT - t0;

        _move(address(0), address(this), minterSupply);
        if (tAdd > 0) _move(address(0), p, tAdd);
        lpMinted = tAdd;

        IWBNB(wbnb).deposit{value: wAdd}();
        if (!IWBNB(wbnb).transfer(p, wAdd)) revert RefundFailed();
        IPancakePair(p).mint(DEAD);
        _seedTwap();
        if (fee > 0) {
            (bool sent,) = devWallet.call{value: fee}("");
            if (!sent) revert RefundFailed();
        }

        inFinalize = false;
        emit Finalized(minterSupply, tAdd, wAdd, balanceOf[p], IWBNB(wbnb).balanceOf(p));
    }

    /// @dev Post-open mint path of `FairToken.mint`.
    function mintOpen(uint256 shares, bytes32 id) external payable onlyToken {
        _mintOpen(shares, id);
    }

    /// @dev Forfeit accounting for the vesting baseline spent by a transfer.
    function noteSale(address user, uint256 amount) external payable onlyToken {
        _noteSale(user, amount);
    }

    /// @dev Day-14 backstop flush of the whole earmark, from `_checkpoint`.
    function flushEarmarkAll() external payable onlyToken {
        _flushEarmark(true, address(0));
    }
}
