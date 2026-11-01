// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {FairToken} from "../src/FairToken.sol";

/// @notice Independent per-holder vest entitlement.
///         Replays each release against the points the holder actually had when
///         `accVest` moved. It does not read `vestDebt`, so a debt that was left
///         at the pre-forfeit watermark cannot satisfy the check.
///
///         Entitlement = immediate unlock
///             + share of every vest release under the points held at that release.
///         A forfeit reduces points before the next release, so the parked tokens
///         are not part of later vest. Redistributed tokens re-enter the pool and
///         are credited only when a later release pays them out. Both are tracked
///         separately (`forfeited`, `redist`) and must match the contract's books.
///
///         Construct this immediately after `finalize`, before any release, and
///         call `sync` after every state-changing action.
contract EntitlementOracle is Test {
    uint256 private constant PREC = 1e18;

    struct Holder {
        uint256 points;
        uint256 vestFair;
        uint256 redist;
        uint256 forfeited;
        uint256 futureSlash;
        uint256 seenCharge;
        uint256 slashed;
    }

    FairToken public token;
    address[] public actors;
    mapping(address => Holder) public shadow;
    uint256 public lastAcc;
    uint256 public lastAccF;
    uint256 public releases;
    uint256 public forfeits;
    uint256 public lastPool;

    constructor(FairToken token_, address[] memory actors_) {
        token = token_;
        uint256 n = actors_.length;
        for (uint256 i; i < n; ++i) {
            actors.push(actors_[i]);
            shadow[actors_[i]].points = _points(actors_[i]);
        }
        lastAcc = token.accVest();
        lastAccF = token.accForfeit();
        lastPool = token.pool();
    }

    function actorLength() external view returns (uint256) {
        return actors.length;
    }

    /// @dev Point changes first (forfeit runs before this block's vest commit),
    ///      then the index deltas on the surviving points.
    function sync() external {
        uint256 acc = token.accVest();
        uint256 accF = token.accForfeit();
        uint256 n = actors.length;
        for (uint256 i; i < n; ++i) {
            address a = actors[i];
            Holder storage h = shadow[a];
            (,,,,,,,,, uint256 forfeitedOut, uint256 forfeitDust,) = token.accounts(a);
            uint256 ptsNow = _points(a);
            if (forfeitedOut > h.forfeited) {
                forfeits += 1;
                h.forfeited = forfeitedOut;
            }
            uint256 chargeNow = token.forfeitChargeOf(a);
            if (chargeNow > h.seenCharge) h.futureSlash += chargeNow - h.seenCharge;
            h.seenCharge = chargeNow;
            assertEq(forfeitDust / PREC, 0, "forfeit not applied");
            h.points = ptsNow;
        }
        lastPool = token.pool();
        if (acc != lastAcc) {
            releases += 1;
            for (uint256 i; i < n; ++i) {
                Holder storage h = shadow[actors[i]];
                uint256 credit = h.points * acc / PREC;
                uint256 prev = h.points * lastAcc / PREC;
                uint256 add = credit > prev ? credit - prev : 0;
                if (add > 0 && h.futureSlash > 0) {
                    uint256 cut = add > h.futureSlash ? h.futureSlash : add;
                    add -= cut;
                    h.futureSlash -= cut;
                    h.slashed += cut;
                }
                h.vestFair += add;
            }
            lastAcc = acc;
        }
        if (accF != lastAccF) {
            for (uint256 i; i < n; ++i) {
                Holder storage h = shadow[actors[i]];
                uint256 credit = h.points * accF / PREC;
                uint256 prev = h.points * lastAccF / PREC;
                if (credit > prev) h.redist += credit - prev;
            }
            lastAccF = accF;
        }
    }

    /// @notice `claimed + claimable` (including vest indexed but not yet crystallized)
    ///         equals the independent entitlement. Over-pay fails outright. Under-pay
    ///         fails beyond a few wei per release or forfeit, and any slack must sit
    ///         with the pool (contract <= oracle).
    function check() external view {
        uint256 n = actors.length;
        uint256 fairVest;
        uint256 distributed;
        uint256 pointSum;
        uint256 slashed;
        // A few wei per release or forfeit. The contract may trail the replay; it must not lead it.
        uint256 slack = 3 * (releases + forfeits + 1);
        // After a forfeit, a later index catch-up can count a floored wei twice in the
        // per-holder sum. `vestAssigned` still cannot pass `vestedOut`, so the extra wei
        // is not payable. Bound that lead by a few wei per forfeit, per holder.
        uint256 leadBound = (forfeits + 1) * (n + 1);
        uint256 dustBound = (releases + 1) * (n + 1);
        for (uint256 i; i < n; ++i) {
            address a = actors[i];
            Holder storage h = shadow[a];
            uint256 fair = _immediate(a) + h.vestFair;
            uint256 got = _owed(a);
            pointSum += h.points;
            fairVest += h.vestFair;
            slashed += h.slashed;
            uint256 imm = _immediate(a);
            if (got > imm) distributed += got - imm;
            assertLe(got, fair, "over-pay");
            assertLe(fair, got + slack, "under-pay");
            assertEq(h.forfeited, _forfeitedOut(a), "forfeit ledger");
            assertLe(_forfeitCredit(a), h.redist + slack, "redistribution missing");
            assertLe(h.redist, _forfeitCredit(a) + slack, "redistribution over-credit");
            uint256 claimedVest = _claimedVest(a);
            assertLe(claimedVest, token.vestGrantedOf(a), "claimed above historical grant");
        }
        assertEq(pointSum, token.totalPoints(), "holders cover every point");
        assertLe(token.vestAssigned(), token.vestedOut(), "assigned above released");
        assertLe(distributed, token.vestedOut() + leadBound, "aggregate over-pay");
        if (fairVest > token.vestedOut()) {
            assertLe(fairVest - token.vestedOut(), leadBound, "index lead");
        } else {
            // Forfeit charges are removed from a holder's replay and routed onward.
            assertLe(token.vestedOut() - fairVest, dustBound + slashed, "unallocated vest dust");
        }
        // After the window, handler warps poke before returning, so earmark is flushed
        // and residual pool dust is burned. Released vest + unallocated dust + burned
        // forfeit + leftover == the original vest pool.
        if (token.launched() && block.timestamp >= token.openTime() + token.forfeitWindow()) {
            uint256 covered = fairVest > token.vestedOut() ? token.vestedOut() : fairVest;
            uint256 dust = token.vestedOut() - covered;
            uint256 lead = fairVest - covered;
            assertLe(token.pool() + token.earmark(), dustBound, "day-14 leftover");
            assertLe(dust, dustBound + slashed, "day-14 dust");
            assertLe(lead, leadBound, "day-14 index lead");
            assertEq(
                covered + dust + token.pool() + token.earmark() + token.burnedLocked(),
                token.initialPool(),
                "vest pool conserved"
            );
            assertLe(fairVest, distributed + slack * n + n, "day-14 under-distributed");
            assertLe(distributed, fairVest + slashed + leadBound, "day-14 over-distributed");
            if (token.pool() == 0 && token.earmark() == 0) {
                uint256 held = token.balanceOf(address(token));
                uint256 tax = token.taxDevReserve() + token.taxLpReserve();
                uint256 unclaimed;
                uint256 charges;
                for (uint256 j; j < n; ++j) {
                    address a = actors[j];
                    (,, uint256 claimable,) = token.unlockState(a);
                    unclaimed += claimable;
                    charges += token.forfeitChargeOf(a);
                }
                if (held >= tax) {
                    // After settlement the contract may hold only unpaid claims, open
                    // forfeit charges, and tax. Anything else is stranded.
                    assertLe(held - tax, unclaimed + charges + dustBound, "stranded vest");
                }
            }
        }
    }

    function _points(address a) internal view returns (uint256) {
        (uint256 shares,, uint256 points,,,,,,,,, bool materialized) = token.accounts(a);
        if (materialized) return points;
        if (!token.launched() || shares == 0) return 0;
        return shares * token.lockedPerShare();
    }

    function _immediate(address a) internal view returns (uint256) {
        (uint256 shares,,,,,,,,,,,) = token.accounts(a);
        if (!token.launched()) return 0;
        return shares * token.immediatePerShare();
    }

    function _forfeitedOut(address a) internal view returns (uint256 forfeitedOut) {
        (,,,,,,,,, forfeitedOut,,) = token.accounts(a);
    }

    /// @dev Index credit of flushed forfeits, including the slice not crystallized yet.
    function _forfeitCredit(address a) internal view returns (uint256) {
        (,,, , uint256 forfeitDebt,, , uint256 received,,,, bool materialized) = token.accounts(a);
        uint256 pts = _points(a);
        uint256 credit = received;
        if (!materialized) {
            // `forfeitDebt` is still 0. Virtual points earn the index once a flush happens.
            pts = _points(a);
        }
        if (pts == 0) return credit;
        uint256 fAcc = pts * token.accForfeit() / PREC;
        if (fAcc > forfeitDebt) credit += fAcc - forfeitDebt;
        return credit;
    }

    function _claimedVest(address a) internal view returns (uint256) {
        (uint256 shares,,,,,,,, uint256 claimed,,,) = token.accounts(a);
        uint256 imm = token.launched() ? shares * token.immediatePerShare() : 0;
        if (claimed <= imm) return 0;
        return claimed - imm;
    }

    /// @dev Storage claimable plus indexed vest not copied yet. Ignores the global
    ///      room cap; `vestAssigned + pending` is checked against `vestedOut` in aggregate.
    function _owed(address a) internal view returns (uint256) {
        (
            uint256 shares,
            ,
            uint256 points,
            uint256 vestDebt,
            ,
            uint256 claimable,
            ,
            ,
            uint256 claimed,
            ,
            ,
            bool materialized
        ) = token.accounts(a);
        uint256 pts = materialized ? points : _points(a);
        uint256 pending;
        if (pts > 0) {
            uint256 vAcc = pts * token.accVest() / PREC;
            if (vAcc > vestDebt) pending = vAcc - vestDebt;
            uint256 charge = token.forfeitChargeOf(a);
            if (pending > charge) pending -= charge;
            else pending = 0;
        }
        uint256 got = claimed + claimable + pending;
        if (token.launched() && !materialized) got += shares * token.immediatePerShare();
        return got;
    }
}
