// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FullMath} from "../src/FullMath.sol";

/// @notice Brute-force vest and forfeit book. No FairToken storage, no indexes.
///         Each holder has a locked wei balance. A transfer forfeits
///         `locked * sold / baseline * rate` immediately. That wei is removed
///         from the seller before anything else is computed, then paid to the
///         other holders in proportion to their locked balances, or burned
///         when the seller is the only one left. Time vest walks the holders
///         in a loop and moves the unlocked slice into claimable.
contract VestModel {
    uint256 internal constant PREC = 1e18;

    struct Holder {
        uint256 shares;
        uint256 locked;
        uint256 claimable;
        uint256 claimed;
        uint256 baseline;
        uint256 forfeited;
        uint256 redist;
        bool seen;
    }

    uint256 public immutable tokensPerShare;
    uint256 public immutable immediateBps;
    uint256 public immutable cliff;
    uint256 public immutable linear;
    uint256 public immutable fullRate;
    uint256 public immutable window;

    address[] public holders;
    mapping(address => Holder) public book;

    uint256 public openTime;
    bool public live;
    uint256 public pool;
    uint256 public vestedOut;
    uint256 public burned;
    uint256 public initialPool;

    constructor(
        uint256 tokensPerShare_,
        uint256 immediateBps_,
        uint256 cliff_,
        uint256 linear_,
        uint256 fullRate_,
        uint256 window_
    ) {
        tokensPerShare = tokensPerShare_;
        immediateBps = immediateBps_;
        cliff = cliff_;
        linear = linear_;
        fullRate = fullRate_;
        window = window_;
    }

    function add(address user, uint256 shares) external {
        Holder storage h = book[user];
        require(!live, "live");
        require(!h.seen, "dup");
        h.seen = true;
        h.shares = shares;
        holders.push(user);
    }

    function finalize(uint256 open) external {
        require(!live, "live");
        live = true;
        openTime = open;
        uint256 n = holders.length;
        uint256 lockedSum;
        for (uint256 i; i < n; ++i) {
            Holder storage h = book[holders[i]];
            uint256 immediate = h.shares * tokensPerShare * immediateBps / 10_000;
            uint256 locked = h.shares * tokensPerShare - immediate;
            h.claimable = immediate;
            h.locked = locked;
            lockedSum += locked;
        }
        pool = lockedSum;
        initialPool = lockedSum;
    }

    function poke(uint256 t) external {
        _sync(t);
    }

    function claim(address user, uint256 t) external returns (uint256 paid) {
        _sync(t);
        Holder storage h = book[user];
        paid = h.claimable;
        if (paid == 0) return 0;
        h.claimable = 0;
        h.claimed += paid;
        h.baseline += paid;
    }

    /// @return taken Locked wei removed from the seller by this transfer.
    function transferOut(address user, uint256 amount, uint256 t) external returns (uint256 taken) {
        _sync(t);
        Holder storage h = book[user];
        if (h.shares == 0 || amount == 0) return 0;
        if (t >= openTime + window) {
            uint256 soldAll = amount > h.baseline ? h.baseline : amount;
            h.baseline -= soldAll;
            return 0;
        }
        uint256 baseline = h.baseline;
        if (baseline == 0) return 0;
        uint256 sold = amount > baseline ? baseline : amount;
        uint256 rate = rateAt(t);
        h.baseline = baseline - sold;
        if (rate == 0 || h.locked == 0) return 0;
        uint256 amt = FullMath.mulDiv(FullMath.mulDiv(h.locked, sold, baseline), rate, PREC);
        if (amt > h.locked) amt = h.locked;
        if (amt == 0) return 0;
        h.locked -= amt;
        h.forfeited += amt;
        pool -= amt;
        _share(user, amt);
        return amt;
    }

    function lockedOf(address user) external view returns (uint256) {
        return book[user].locked;
    }

    function forfeitedOf(address user) external view returns (uint256) {
        return book[user].forfeited;
    }

    /// @notice Everything this holder can still receive, plus what they already claimed.
    function receivable(address user) external view returns (uint256) {
        Holder storage h = book[user];
        return h.claimed + h.claimable + h.locked;
    }

    function rateAt(uint256 t) public view returns (uint256) {
        if (!live) return 0;
        uint256 fullUntil = openTime + fullRate;
        uint256 end = openTime + window;
        if (t >= end) return 0;
        if (t <= fullUntil) return PREC;
        uint256 span = end - fullUntil;
        uint256 elapsed = t - fullUntil;
        return PREC - (elapsed * PREC) / span;
    }

    function _sync(uint256 t) internal {
        if (!live || pool == 0) return;
        uint256 frac = _timeFrac(t);
        uint256 base = initialPool - burned;
        if (base == 0) return;
        uint256 target = base * frac / PREC;
        if (target <= vestedOut) return;
        uint256 delta = target - vestedOut;
        if (delta > pool) delta = pool;
        uint256 poolBefore = pool;
        uint256 n = holders.length;
        uint256 assigned;
        for (uint256 i; i < n; ++i) {
            Holder storage h = book[holders[i]];
            if (h.locked == 0) continue;
            uint256 cut = h.locked * delta / poolBefore;
            h.locked -= cut;
            h.claimable += cut;
            assigned += cut;
        }
        pool -= assigned;
        vestedOut += assigned;
        if (frac == PREC && pool > 0 && pool <= n) {
            burned += pool;
            pool = 0;
            for (uint256 i; i < n; ++i) {
                book[holders[i]].locked = 0;
            }
        }
    }

    function _share(address seller, uint256 amt) internal {
        uint256 n = holders.length;
        uint256 others;
        for (uint256 i; i < n; ++i) {
            if (holders[i] == seller) continue;
            others += book[holders[i]].locked;
        }
        if (others == 0) {
            burned += amt;
            return;
        }
        uint256 credited;
        for (uint256 i; i < n; ++i) {
            if (holders[i] == seller) continue;
            Holder storage h = book[holders[i]];
            if (h.locked == 0) continue;
            uint256 add = amt * h.locked / others;
            h.locked += add;
            h.redist += add;
            credited += add;
        }
        uint256 dust = amt - credited;
        if (dust > 0) burned += dust;
        pool += credited;
    }

    function _timeFrac(uint256 t) internal view returns (uint256) {
        uint256 start = openTime + cliff;
        if (t <= start) return 0;
        uint256 end = start + linear;
        if (t >= end) return PREC;
        return (t - start) * PREC / linear;
    }
}
