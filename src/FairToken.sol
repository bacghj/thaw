// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FairTokenBase} from "./FairTokenBase.sol";
import {FairTokenExt} from "./FairTokenExt.sol";
import {FairTokenParams} from "./FairTokenParams.sol";
import {IPancakePair} from "./interfaces/IPancakeV2.sol";
import {FullMath} from "./FullMath.sol";

/// @title FairToken
/// @notice Ownerless fair-mint ERC-20. No admin, pause, blacklist, upgrade, or team allocation.
///
/// Mint (FCFS, three price tiers). Only Agent-ID wallets may mint. Contract callers are rejected,
/// except EIP-7702 delegated EOAs whose code is exactly 23 bytes starting with 0xef0100.
/// If the soft cap is missed, anyone can open refunds and every minter withdraws 100% of BNB paid.
///
/// Finalize (anyone, once the hard cap is filled or the window ended at/above the soft cap):
/// minters are allocated `sold * tokensPerShare` tokens (constant tokens per share, so cheaper
/// tiers have a better cost basis). `mintFeeBps` of raised BNB is sent to `devWallet`. The pair
/// receives the other 90% (by default) plus however many tokens make the opening price
/// `premiumNum/premiumDen` times the average mint cost of the full raise. LP tokens are minted
/// to the dead address. Liquidity is seeded by transferring WBNB and tokens straight to the pair
/// and calling `mint` — not `router.addLiquidity` — and donated reserves are included in the price
/// math so a pre-seeded pair cannot block finalize or move the price.
///
/// After open, unsold shares can still be minted until `hardCap`. The price is `tokensPerShare`
/// times a Pancake V2 cumulative-price TWAP of at least `twapWindow`, never the spot price.
/// Same-block swaps add zero seconds to that average. 10% of the BNB goes to `devWallet` and 90%
/// is paired with new tokens at the current reserve ratio (the add does not move the price) and
/// the LP is minted to dead. Those tokens are unlocked and are not vesting shares.
///
/// Unlock: `immediateUnlockBps` is claimable at open. The rest vests with demand
/// (for every `demandDen` tokens of committed net buying, `demandNum` locked tokens unlock)
/// and a linear time backstop from `open + vestCliff` to `open + vestCliff + vestLinear`.
/// Net buy volume is a high-water mark committed only on a later block, so a same-transaction
/// flash round-trip cannot advance it.
///
/// Forfeit (sellers): from open through `forfeitFullRate` the multiplier is 100%. It then falls
/// linearly to 0% at `open + forfeitWindow`. Selling or transferring out X% of claimed minter
/// tokens forfeits X% * rate(t) of the still-locked balance. Forfeits are redistributed to the
/// other locked balances. Above six live holders that is a global index (the sender and the
/// globals only). At six or fewer it is an integer walk, matching the reference model. A sole
/// remaining holder is not paid their own forfeit; it is burned.
/// Sub-`minUnit` forfeits are parked immediately (they cannot vest) and flushed in `minUnit` chunks.
///
/// Tax: 3% on buys and sells against the official pair only (1.5% dev BNB via swapback, 1.5% auto-LP
/// burned to dead). Wallet-to-wallet transfers are untaxed. Swapback is try/catch and cannot revert a sell.
///
/// Code layout (no behaviour change): storage, immutables and internals are declared in
/// `FairTokenBase`. `finalize`, post-open minting, the forfeit path of a transfer, and the
/// day-14 earmark flush run in `FairTokenExt`, deployed by this constructor with the same
/// parameters and called only by DELEGATECALL, so they act on this contract's storage and
/// balance. The extension address is immutable; there is no way to change it.
contract FairToken is FairTokenBase {
    // -------------------------------------------------------------------------
    // Errors (names are the human-readable reason)
    // -------------------------------------------------------------------------

    /// @notice Constructor argument failed a sanity check. `what` names the field.
    error InvalidParams(string what);
    /// @notice Mint window is closed, refunds are open, or the hard cap is already sold.
    error MintClosed();
    /// @notice The first TWAP window has not elapsed, so post-open minting is not priced yet.
    error TwapNotReady();
    /// @notice Spot price is too far from the TWAP, so the mint is refused.
    error TwapDeviation();
    /// @notice `msg.value` does not equal the tier quote.
    error WrongPayment(uint256 expected, uint256 actual);
    /// @notice Requested shares exceed the remaining hard cap.
    error CapExceeded(uint256 remaining, uint256 requested);
    /// @notice This wallet would hold more than `maxPerWallet` shares.
    error WalletCapExceeded(uint256 max, uint256 already, uint256 requested);
    /// @notice This Agent ID would hold more than `maxPerIdentity` shares.
    error IdentityCapExceeded(uint256 max, uint256 already, uint256 requested);
    /// @notice Verifier returned no Agent ID for this wallet.
    error NotAgent(address account);
    /// @notice Caller has contract code that is not an EIP-7702 delegation (0xef0100 || address).
    error ContractCallerNotAllowed(address account);
    /// @notice Finalize conditions are not met (need a full cap, or deadline plus soft cap).
    error FinalizeNotReady();
    /// @notice Pool is already live, or refunds were already opened.
    error AlreadyFinalized();
    /// @notice Refund trigger was called before the deadline.
    error TooEarly(uint256 deadline, uint256 nowTs);
    /// @notice Soft cap was reached, so refunds cannot open.
    error SoftCapMet();
    /// @notice Refunds are not open.
    error RefundNotActive();
    /// @notice This wallet has nothing to refund.
    error NothingToRefund();
    /// @notice BNB transfer failed.
    error RefundFailed();
    /// @notice Pool is not live yet.
    error NotLive();
    /// @notice Nothing is currently claimable.
    error NothingToClaim();
    /// @notice Token transfers are disabled until finalize. Claims use `claim()`, not `transfer`.
    error TransferDisabled();
    /// @notice Plain BNB transfers are rejected. Mint via `mint()` so the payment is accounted.
    error DirectBnbRejected();
    /// @notice Reentrant call, or a call during swapback / finalize.
    error Reentrancy();
    /// @notice Swapback entrypoint called by someone other than this contract.
    error Forbidden();
    /// @notice ERC-20 balance too low.
    error InsufficientBalance();
    /// @notice ERC-20 allowance too low.
    error InsufficientAllowance();
    /// @notice Zero shares.
    error ZeroShares();

    /// @notice Logic extension created in the constructor. Immutable. Reached only via DELEGATECALL.
    address public immutable extension;

    constructor(Params memory p) FairTokenBase(p) {
        name = p.name;
        symbol = p.symbol;
        extension = address(new FairTokenExt(p));
    }

    /// @dev All constructor argument checks live in the linked library `FairTokenParams`
    ///      (external, so its code is not part of this contract's initcode). Reverts bubble unchanged.
    function _validateParams(Params memory p) internal pure override {
        FairTokenParams.validate(p);
    }

    // -------------------------------------------------------------------------
    // Reads
    // -------------------------------------------------------------------------

    function phaseName(uint8 phase) public pure returns (string memory) {
        if (phase == 0) return "mint";
        if (phase == 1) return "pending";
        if (phase == 2) return "refund";
        if (phase == 3) return "live";
        return "refund-ready";
    }

    function currentPhase() public view returns (uint8) {
        if (launched) return 3;
        if (refundMode) return 2;
        if (block.timestamp >= deadline && sold < softCap) return 4;
        if (sold == hardCap || (block.timestamp >= deadline && sold >= softCap)) return 1;
        return 0;
    }

    function status() external view returns (LaunchStatus memory s) {
        s.phase = currentPhase();
        s.sold = sold;
        s.deadline = deadline;
        s.softCap = softCap;
        s.hardCap = hardCap;
        s.raised = raised;
        s.forfeitRateWad = launched ? _forfeitRateAt(block.timestamp) : 0;
        s.spotPriceWad = _spotPrice();
        uint256 cursor = sold == 0 ? 0 : (sold >= hardCap ? hardCap - 1 : sold);
        (s.tier, s.priceWei) = _tierAt(cursor);
    }

    /// @notice BNB cost and token output for `shares` bought at the current cursor.
    ///         Reverts if `shares` does not fit in the remaining cap. Token output does not depend on tier.
    function quote(uint256 shares) external view returns (uint256 bnbCost, uint256 tokensOut) {
        if (shares == 0) return (0, 0);
        if (sold + shares > hardCap) revert CapExceeded(hardCap - sold, shares);
        if (launched) return _quoteOpen(shares);
        bnbCost = _cost(sold, shares);
        tokensOut = shares * tokensPerShare;
    }

    /// @notice Post-open price. `bnbCost` is `tokensPerShare * shares` times the TWAP (BNB per token).
    function quoteOpen(uint256 shares) external view returns (uint256 bnbCost, uint256 tokensOut) {
        return _quoteOpen(shares);
    }

    function unlockState(address account)
        external
        view
        returns (uint256 locked, uint256 unlocked, uint256 claimable, uint256 forfeitedReceived)
    {
        if (exactMode) {
            Account storage a = accounts[account];
            uint256 w = _exactWei(account);
            uint256 cut = _exactPendingCut(w);
            claimable = a.claimable + cut;
            if (launched && a.shares > 0 && !a.materialized) claimable += a.shares * immediatePerShare;
            locked = w > cut ? w - cut : 0;
            forfeitedReceived = a.forfeitedReceived;
            unlocked = a.claimed + claimable;
            return (locked, unlocked, claimable, forfeitedReceived);
        }
        (uint256 acc,, uint256 scaleAfter) = _previewVest();
        Account storage a = accounts[account];
        uint256 pending = _vestGain(account, acc);
        uint256 room = vestedOut > vestAssigned ? vestedOut - vestAssigned : 0;
        if (pending > room) pending = room;
        claimable = a.claimable + pending;
        if (launched && a.shares > 0 && !a.materialized) claimable += a.shares * immediatePerShare;
        uint256 raw = _virtualRaw(account);
        locked = raw == 0 ? 0 : FullMath.mulDiv(raw, scaleAfter, PREC * RAW);
        forfeitedReceived = a.forfeitedReceived + _pendingRedist(account, scaleAfter);
        unlocked = a.claimed + claimable;
    }

    /// @notice Forfeit multiplier in 1e18 wad. 100% through `open + forfeitFullRate`, then linear to 0 at `open + forfeitWindow`.
    function forfeitRateAt(uint256 t) public view returns (uint256) {
        return _forfeitRateAt(t);
    }

    /// @notice BNB per token from the cumulative-price window. Reverts before the first full window.
    function twapPrice() public view returns (uint256 wbnbPerTokenWad) {
        return _consultTwap();
    }

    function spotPrice() public view returns (uint256 wbnbPerTokenWad) {
        return _spotPrice();
    }

    function previewHwm() public view returns (uint256 h) {
        return _previewHwm();
    }

    /// @notice Raw shares including unsettled redistribution. Sums to `totalPoints`.
    function rawOf(address user) external view returns (uint256) {
        return _virtualRaw(user);
    }

    /// @notice `claimed + claimable`, using the committed vest index (no hypothetical release).
    function vestedOwed(address user) external view returns (uint256) {
        Account storage a = accounts[user];
        if (exactMode) {
            // Committed only. A hypothetical release belongs in `unlockState`, not here.
            uint256 committed = a.claimable;
            if (launched && a.shares > 0 && !a.materialized) committed += a.shares * immediatePerShare;
            return a.claimed + committed;
        }
        uint256 pending = _vestGain(user, accVest);
        uint256 room = vestedOut > vestAssigned ? vestedOut - vestAssigned : 0;
        if (pending > room) pending = room;
        uint256 out = a.claimable + pending;
        if (launched && a.shares > 0 && !a.materialized) out += a.shares * immediatePerShare;
        return a.claimed + out;
    }

    /// @notice Buy `shares`. Before open, the price is the tier quote. After open, unsold shares
    ///         cost `tokensPerShare` times the TWAP and are delivered unlocked.
    ///         Rejects contract code unless it is an EIP-7702 delegation designator:
    ///         exactly 23 bytes, prefix 0xef0100, then a 20-byte address.
    function mint(uint256 shares) external payable nonReentrant {
        if (refundMode) revert MintClosed();
        if (shares == 0) revert ZeroShares();
        _requireEoa(msg.sender);
        (bool ok, bytes32 id) = verifier.verify(msg.sender);
        if (!ok || id == bytes32(0)) revert NotAgent(msg.sender);
        if (launched) _delegate(abi.encodeCall(FairTokenExt.mintOpen, (shares, id)));
        else _mintSubscribe(shares, id);
    }

    function _mintSubscribe(uint256 shares, bytes32 id) internal {
        if (block.timestamp >= deadline) revert MintClosed();
        Account storage a = accounts[msg.sender];
        if (a.shares + shares > maxPerWallet) revert WalletCapExceeded(maxPerWallet, a.shares, shares);
        if (idShares[id] + shares > maxPerIdentity) revert IdentityCapExceeded(maxPerIdentity, idShares[id], shares);
        if (sold + shares > hardCap) revert CapExceeded(hardCap - sold, shares);

        uint256 cost = _cost(sold, shares);
        if (msg.value != cost) revert WrongPayment(cost, msg.value);

        sold += shares;
        raised += msg.value;
        if (a.shares == 0) _linkHolder(msg.sender);
        a.shares += shares;
        a.paid += msg.value;
        idShares[id] += shares;
        emit Minted(msg.sender, id, shares, msg.value);
    }

    function triggerRefund() external {
        if (launched || refundMode) revert AlreadyFinalized();
        if (block.timestamp < deadline) revert TooEarly(deadline, block.timestamp);
        if (sold >= softCap) revert SoftCapMet();
        refundMode = true;
        emit RefundTriggered();
    }

    function refund() external nonReentrant {
        if (!refundMode) revert RefundNotActive();
        Account storage a = accounts[msg.sender];
        uint256 amt = a.paid;
        if (amt == 0) revert NothingToRefund();
        a.paid = 0;
        raised -= amt;
        (bool ok,) = msg.sender.call{value: amt}("");
        if (!ok) revert RefundFailed();
        emit Refunded(msg.sender, amt);
    }

    /// @notice Open the pool. Seeds the official pair directly (no `router.addLiquidity`).
    ///         Donated WBNB that was synced into reserves is offset by extra LP tokens so the
    ///         price stays `premium` times average mint cost. Unsynced donations are skimmed to dead.
    function finalize() external nonReentrant {
        _delegate(abi.encodeCall(FairTokenExt.finalize, ()));
    }

    /// @notice Commit the net-buy high-water mark (it only moves forward on a later block) and vest.
    ///         Permissionless. Does not move funds.
    function poke() external nonReentrant {
        if (!launched) revert NotLive();
        _checkpoint();
    }

    function claim() external nonReentrant {
        if (!launched) revert NotLive();
        _checkpoint();
        _ensurePoints(msg.sender);
        _crystallize(msg.sender);
        if (block.timestamp >= openTime + forfeitWindow) _burnUnindexedVest();
        Account storage a = accounts[msg.sender];
        uint256 amt = a.claimable;
        if (amt == 0) revert NothingToClaim();
        a.claimable = 0;
        a.liquidBaseline += amt;
        a.claimed += amt;
        claimedTotal += amt;
        _move(address(this), msg.sender, amt);
        emit Claimed(msg.sender, amt);
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _update(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < value) revert InsufficientAllowance();
            allowance[from][msg.sender] = allowed - value;
            emit Approval(from, msg.sender, allowance[from][msg.sender]);
        }
        _update(from, to, value);
        return true;
    }

    /// @dev Swapback is external so the sell path can try/catch it. Only this contract may call it.
    ///      Returns the token amounts that were not consumed, so a router that deposits
    ///      only part of the requested liquidity cannot erase the remainder from the books.
    function execSwapBack(uint256 devAmt, uint256 lpAmt) external returns (uint256 devLeft, uint256 lpLeft) {
        if (msg.sender != address(this)) revert Forbidden();
        return _execSwapBack(devAmt, lpAmt);
    }

    receive() external payable {
        // Mint payments hit `mint()` and never this function. Only WBNB unwraps and the router
        // (swapback / liquidity refunds) may deliver BNB. Anything else is rejected so it cannot
        // be mistaken for raised funds. There is no withdraw function for stray BNB.
        if (msg.sender != wbnb && msg.sender != router) revert DirectBnbRejected();
    }

    function _update(address from, address to, uint256 value) internal {
        if (from == address(0) || value == 0) {
            _move(from, to, value);
            return;
        }
        if (inFinalize) {
            _move(from, to, value);
            return;
        }
        if (_lock != 1 && !inSwap) revert Reentrancy();

        // Protocol-originated transfers (claim is `_move`; swapback and tax LP come through here).
        if (from == address(this)) {
            if (launched && to == pair) {
                liveNet -= int256(value);
            }
            _move(from, to, value);
            return;
        }
        // While swapback is in progress, only this contract may move tokens.
        // A dev-wallet callback cannot push an untaxed transfer through.
        if (inSwap) revert Reentrancy();
        if (!launched) revert TransferDisabled();

        // Unlock whatever time has already earned, then forfeit only the vesting baseline
        // that this transfer actually spends. Free tokens (post-open mints, buys, inbound
        // transfers) are consumed first and never forfeit. Self-transfers are not sells.
        _checkpoint();
        if (from != pair && from != to) {
            uint256 fromBaseline = _spendFree(from, value);
            // Same early exit as `_noteSale`: only minters with a spent baseline reach the extension.
            if (accounts[from].shares != 0 && fromBaseline != 0) {
                _delegate(abi.encodeCall(FairTokenExt.noteSale, (from, fromBaseline)));
            }
        }

        // A pair-to-pair move (skim to the pair, sync leftovers routed back) does not
        // take tokens out of the pool. Counting it as a buy lets the same balance
        // raise the high-water mark on every call.
        if (from == pair && to == pair) {
            _move(from, to, value);
            return;
        }

        bool isBuy = from == pair;
        bool isSell = to == pair;
        if (!isBuy && !isSell) {
            _move(from, to, value);
            if (to != from) _creditFree(to, value);
            return;
        }

        if (isSell) _swapBack();

        uint256 fee = value * TAX_BPS / BPS;
        uint256 devFee = value * DEV_BPS / BPS;
        uint256 lpFee = fee - devFee;
        taxDevReserve += devFee;
        taxLpReserve += lpFee;
        _move(from, to, value - fee);
        if (fee > 0) _move(from, address(this), fee);
        if (isBuy) _creditFree(to, value - fee);

        if (isBuy) liveNet += int256(value);
        else liveNet -= int256(value - fee);
    }

    function _swapBack() internal {
        if (inSwap || pair == address(0)) return;
        uint256 devAmt = taxDevReserve;
        uint256 lpAmt = taxLpReserve;
        if (devAmt + lpAmt < swapThreshold) return;
        inSwap = true;
        try this.execSwapBack(devAmt, lpAmt) returns (uint256 devLeft, uint256 lpLeft) {
            taxDevReserve = devLeft;
            taxLpReserve = lpLeft;
        } catch {}
        inSwap = false;
    }

    function _checkpoint() internal {
        if (!launched) return;
        _observeTwap();
        if (block.number > lastCommitBlock) {
            if (liveNet > 0 && uint256(liveNet) > hwmNet) hwmNet = uint256(liveNet);
            lastCommitBlock = block.number;
        }
        if (block.timestamp >= openTime + forfeitWindow && earmark > 0) {
            _delegate(abi.encodeCall(FairTokenExt.flushEarmarkAll, ()));
        }
        _releaseLocked();
        if (block.timestamp >= openTime + forfeitWindow) _burnUnindexedVest();
    }

    /// @dev Run `data` in `extension` against this contract's storage. Reverts bubble up unchanged.
    function _delegate(bytes memory data) private {
        (bool ok, bytes memory ret) = extension.delegatecall(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }
}
