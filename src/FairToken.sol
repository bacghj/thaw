// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAgentIdVerifier} from "./interfaces/IAgentIdVerifier.sol";
import {IPancakeFactory, IPancakePair, IPancakeRouter, IWBNB} from "./interfaces/IPancakeV2.sol";
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
/// tiers have a better cost basis). The pair receives `minterSupply * premiumDen / premiumNum`
/// tokens plus 100% of raised BNB, so the opening price is `premiumNum/premiumDen` times the
/// average mint cost. LP tokens are minted to the dead address. Liquidity is seeded by transferring
/// WBNB and tokens straight to the pair and calling `mint` — not `router.addLiquidity` — and donated
/// reserves are included in the price math so a pre-seeded pair cannot block finalize or move the price.
///
/// Unlock: `immediateUnlockBps` is claimable at open. The rest vests with demand
/// (for every `demandDen` tokens of committed net buying, `demandNum` locked tokens unlock)
/// and a linear time backstop from `open + vestCliff` to `open + vestCliff + vestLinear`.
/// Net buy volume is a high-water mark committed only on a later block, so a same-transaction
/// flash round-trip cannot advance it.
///
/// Forfeit (sellers): from open through `forfeitFullRate` the multiplier is 100%. It then falls
/// linearly to 0% at `open + forfeitWindow`. Selling or transferring out X% of claimed minter
/// tokens forfeits X% * rate(t) of the still-locked balance. Forfeits are redistributed O(1)
/// across remaining locked balances. A sole remaining holder is not paid their own forfeit; it is burned.
/// Sub-`minUnit` forfeits are parked immediately (they cannot vest) and flushed in `minUnit` chunks.
///
/// Tax: 3% on buys and sells against the official pair only (1.5% dev BNB via swapback, 1.5% auto-LP
/// burned to dead). Wallet-to-wallet transfers are untaxed. Swapback is try/catch and cannot revert a sell.
contract FairToken {
    // -------------------------------------------------------------------------
    // Errors (names are the human-readable reason)
    // -------------------------------------------------------------------------

    /// @notice Constructor argument failed a sanity check. `what` names the field.
    error InvalidParams(string what);
    /// @notice Mint window is closed, refunds are open, or the pool is already live.
    error MintClosed();
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

    // -------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------

    struct Params {
        string name;
        string symbol;
        address verifier;
        address devWallet;
        address router;
        address factory;
        address wbnb;
        uint256 hardCap;
        uint256 softCap;
        uint256 tier1Price;
        uint256 tier2Price;
        uint256 tier3Price;
        uint16 tier1Bps;
        uint16 tier2Bps;
        uint256 maxPerWallet;
        uint256 maxPerIdentity;
        uint256 mintDuration;
        uint256 tokensPerShare;
        uint256 premiumNum;
        uint256 premiumDen;
        uint16 immediateUnlockBps;
        uint256 demandNum;
        uint256 demandDen;
        uint256 vestCliff;
        uint256 vestLinear;
        uint256 forfeitFullRate;
        uint256 forfeitWindow;
        uint256 swapThreshold;
        uint256 minUnit;
    }

    struct Account {
        uint256 shares;
        uint256 paid;
        uint256 points;
        uint256 vestDebt;
        uint256 forfeitDebt;
        uint256 claimable;
        uint256 liquidBaseline;
        uint256 forfeitedReceived;
        uint256 claimed;
        uint256 forfeitedOut;
        uint256 forfeitDust; // scaled by PREC; sub-wei remainder of an unpulled forfeit
        bool materialized;
    }

    /// @notice phase: 0 mint, 1 pending finalize, 2 refund, 3 live, 4 refund-ready (not yet triggered).
    struct LaunchStatus {
        uint8 phase;
        uint256 sold;
        uint8 tier;
        uint256 priceWei;
        uint256 deadline;
        uint256 softCap;
        uint256 hardCap;
        uint256 raised;
        uint256 forfeitRateWad;
        uint256 spotPriceWad;
    }

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    uint256 public constant TAX_BPS = 300;
    uint256 public constant DEV_BPS = 150;
    uint256 public constant LP_BPS = 150;
    uint256 public constant BPS = 10_000;
    uint256 public constant PREC = 1e18;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // -------------------------------------------------------------------------
    // Immutables
    // -------------------------------------------------------------------------

    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    IAgentIdVerifier public immutable verifier;
    address public immutable devWallet;
    address public immutable router;
    address public immutable factory;
    address public immutable wbnb;

    uint256 public immutable hardCap;
    uint256 public immutable softCap;
    uint256 public immutable tier1Price;
    uint256 public immutable tier2Price;
    uint256 public immutable tier3Price;
    uint256 public immutable tier1End;
    uint256 public immutable tier2End;
    uint256 public immutable maxPerWallet;
    uint256 public immutable maxPerIdentity;
    uint256 public immutable deadline;
    uint256 public immutable tokensPerShare;
    uint256 public immutable immediatePerShare;
    uint256 public immutable lockedPerShare;
    uint256 public immutable premiumNum;
    uint256 public immutable premiumDen;
    uint256 public immutable demandNum;
    uint256 public immutable demandDen;
    uint256 public immutable vestCliff;
    uint256 public immutable vestLinear;
    uint256 public immutable forfeitFullRate;
    uint256 public immutable forfeitWindow;
    uint256 public immutable swapThreshold;
    uint256 public immutable minUnit;

    // -------------------------------------------------------------------------
    // ERC-20 / launch state. `pair` is written once inside `finalize` from the factory.
    // -------------------------------------------------------------------------

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    mapping(address => Account) public accounts;
    mapping(bytes32 => uint256) public idShares;

    uint256 public sold;
    uint256 public raised;
    bool public launched;
    bool public refundMode;
    uint256 public openTime;
    address public pair;

    uint256 public minterSupply;
    uint256 public lpMinted;
    uint256 public pool;
    uint256 public totalPoints;
    uint256 public accVest;
    uint256 public accForfeit;
    uint256 public vestedOut;
    uint256 public burnedLocked;
    uint256 public earmark;
    uint256 public initialPool;
    uint256 public claimedTotal;

    int256 public liveNet;
    uint256 public hwmNet;
    uint256 public lastCommitBlock;

    uint256 public taxDevReserve;
    uint256 public taxLpReserve;

    bool private inSwap;
    bool private inFinalize;
    uint256 private _lock = 1;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Minted(address indexed user, bytes32 indexed identity, uint256 shares, uint256 paid);
    event RefundTriggered();
    event Refunded(address indexed user, uint256 amount);
    event Finalized(uint256 minterSupply, uint256 lpTokens, uint256 raised, uint256 tokenReserve, uint256 wbnbReserve);
    event Claimed(address indexed user, uint256 amount);
    event Forfeited(address indexed user, uint256 parked, uint256 redistributed, uint256 burned);
    event SwapBack(uint256 devTokens, uint256 lpTokens);

    constructor(Params memory p) {
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

        name = p.name;
        symbol = p.symbol;
        verifier = IAgentIdVerifier(p.verifier);
        devWallet = p.devWallet;
        router = p.router;
        factory = p.factory;
        wbnb = p.wbnb;
        hardCap = p.hardCap;
        softCap = p.softCap;
        tier1Price = p.tier1Price;
        tier2Price = p.tier2Price;
        tier3Price = p.tier3Price;
        tier1End = t1;
        tier2End = t2;
        maxPerWallet = p.maxPerWallet;
        maxPerIdentity = p.maxPerIdentity;
        deadline = block.timestamp + p.mintDuration;
        tokensPerShare = p.tokensPerShare;
        immediatePerShare = immediate;
        lockedPerShare = locked;
        premiumNum = p.premiumNum;
        premiumDen = p.premiumDen;
        demandNum = p.demandNum;
        demandDen = p.demandDen;
        vestCliff = p.vestCliff;
        vestLinear = p.vestLinear;
        forfeitFullRate = p.forfeitFullRate;
        forfeitWindow = p.forfeitWindow;
        swapThreshold = p.swapThreshold;
        minUnit = p.minUnit;
    }

    modifier nonReentrant() {
        if (_lock != 1 || inSwap || inFinalize) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
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
        s.forfeitRateWad = launched ? forfeitRateAt(block.timestamp) : 0;
        s.spotPriceWad = spotPrice();
        uint256 cursor = sold == 0 ? 0 : (sold >= hardCap ? hardCap - 1 : sold);
        (s.tier, s.priceWei) = _tierAt(cursor);
    }

    /// @notice BNB cost and token output for `shares` bought at the current cursor.
    ///         Reverts if `shares` does not fit in the remaining cap. Token output does not depend on tier.
    function quote(uint256 shares) external view returns (uint256 bnbCost, uint256 tokensOut) {
        if (shares == 0) return (0, 0);
        if (sold + shares > hardCap) revert CapExceeded(hardCap - sold, shares);
        bnbCost = _cost(sold, shares);
        tokensOut = shares * tokensPerShare;
    }

    function unlockState(address account)
        external
        view
        returns (uint256 locked, uint256 unlocked, uint256 claimable, uint256 forfeitedReceived)
    {
        (uint256 acc, uint256 poolAfter) = _previewVest();
        Account storage a = accounts[account];
        uint256 pts = a.materialized ? a.points : (launched ? a.shares * lockedPerShare : 0);
        uint256 pending;
        if (pts > 0) {
            uint256 got = pts * acc / PREC;
            if (got > a.vestDebt) pending = got - a.vestDebt;
        }
        claimable = a.claimable + pending;
        if (launched && a.shares > 0 && !a.materialized) claimable += a.shares * immediatePerShare;
        locked = (totalPoints == 0 || pts == 0) ? 0 : pts * poolAfter / totalPoints;
        forfeitedReceived = a.forfeitedReceived;
        if (pts > 0) {
            uint256 fg = pts * accForfeit / PREC;
            if (fg > a.forfeitDebt) forfeitedReceived += fg - a.forfeitDebt;
        }
        unlocked = a.claimed + claimable;
    }

    /// @notice Forfeit multiplier in 1e18 wad. 100% through `open + forfeitFullRate`, then linear to 0 at `open + forfeitWindow`.
    function forfeitRateAt(uint256 t) public view returns (uint256) {
        if (!launched) return 0;
        uint256 fullUntil = openTime + forfeitFullRate;
        uint256 end = openTime + forfeitWindow;
        if (t >= end) return 0;
        if (t <= fullUntil) return PREC;
        uint256 span = end - fullUntil;
        uint256 elapsed = t - fullUntil;
        return PREC - (elapsed * PREC) / span;
    }

    function spotPrice() public view returns (uint256 wbnbPerTokenWad) {
        if (pair == address(0)) return 0;
        (uint112 r0, uint112 r1,) = IPancakePair(pair).getReserves();
        bool tokenIs0 = IPancakePair(pair).token0() == address(this);
        uint256 rT = tokenIs0 ? uint256(r0) : uint256(r1);
        uint256 rW = tokenIs0 ? uint256(r1) : uint256(r0);
        if (rT == 0) return 0;
        return rW * PREC / rT;
    }

    function previewHwm() public view returns (uint256 h) {
        h = hwmNet;
        if (launched && block.number > lastCommitBlock && liveNet > int256(h)) h = uint256(liveNet);
    }

    // -------------------------------------------------------------------------
    // Mint / refund / finalize / claim
    // -------------------------------------------------------------------------

    /// @notice Buy `shares` at the current tier quote. `msg.value` must equal `quote`.
    ///         Rejects contract code unless it is an EIP-7702 delegation designator:
    ///         exactly 23 bytes, prefix 0xef0100, then a 20-byte address.
    function mint(uint256 shares) external payable nonReentrant {
        if (launched || refundMode || block.timestamp >= deadline) revert MintClosed();
        if (shares == 0) revert ZeroShares();
        _requireEoa(msg.sender);
        (bool ok, bytes32 id) = verifier.verify(msg.sender);
        if (!ok || id == bytes32(0)) revert NotAgent(msg.sender);

        Account storage a = accounts[msg.sender];
        if (a.shares + shares > maxPerWallet) revert WalletCapExceeded(maxPerWallet, a.shares, shares);
        if (idShares[id] + shares > maxPerIdentity) revert IdentityCapExceeded(maxPerIdentity, idShares[id], shares);
        if (sold + shares > hardCap) revert CapExceeded(hardCap - sold, shares);

        uint256 cost = _cost(sold, shares);
        if (msg.value != cost) revert WrongPayment(cost, msg.value);

        sold += shares;
        raised += msg.value;
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
        totalPoints = initialPool;

        address p = IPancakeFactory(factory).getPair(address(this), wbnb);
        if (p == address(0)) p = IPancakeFactory(factory).createPair(address(this), wbnb);
        pair = p;

        // Drop donations that were not synced. Synced donations stay in reserves and are priced in below.
        IPancakePair(p).skim(DEAD);

        uint256 t0 = balanceOf[p];
        uint256 w0 = IWBNB(wbnb).balanceOf(p);
        uint256 wAdd = raised;
        uint256 finalT = FullMath.mulDiv(w0 + wAdd, minterSupply * premiumDen, wAdd * premiumNum);
        uint256 tAdd = t0 >= finalT ? 0 : finalT - t0;

        _move(address(0), address(this), minterSupply);
        if (tAdd > 0) _move(address(0), p, tAdd);
        lpMinted = tAdd;

        IWBNB(wbnb).deposit{value: wAdd}();
        if (!IWBNB(wbnb).transfer(p, wAdd)) revert RefundFailed();
        IPancakePair(p).mint(DEAD);

        inFinalize = false;
        emit Finalized(minterSupply, tAdd, wAdd, balanceOf[p], IWBNB(wbnb).balanceOf(p));
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

    // -------------------------------------------------------------------------
    // ERC-20
    // -------------------------------------------------------------------------

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
    function execSwapBack(uint256 devAmt, uint256 lpAmt) external {
        if (msg.sender != address(this)) revert Forbidden();
        _execSwapBack(devAmt, lpAmt);
    }

    receive() external payable {
        // Mint payments hit `mint()` and never this function. Only WBNB unwraps and the router
        // (swapback / liquidity refunds) may deliver BNB. Anything else is rejected so it cannot
        // be mistaken for raised funds. There is no withdraw function for stray BNB.
        if (msg.sender != wbnb && msg.sender != router) revert DirectBnbRejected();
    }

    // -------------------------------------------------------------------------
    // Internal: transfers, tax, net flow
    // -------------------------------------------------------------------------

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

        // Forfeit before this block's vest commit so the penalty uses still-locked tokens.
        // Self-transfers do not leave the wallet, so they are not sells.
        if (from != pair && from != to) _noteSale(from, value);

        _checkpoint();

        bool isBuy = from == pair;
        bool isSell = to == pair;
        if (!isBuy && !isSell) {
            _move(from, to, value);
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

        if (isBuy) liveNet += int256(value);
        else liveNet -= int256(value - fee);
    }

    function _move(address from, address to, uint256 value) internal {
        if (from == address(0)) {
            totalSupply += value;
        } else {
            uint256 bal = balanceOf[from];
            if (bal < value) revert InsufficientBalance();
            balanceOf[from] = bal - value;
        }
        if (to == address(0)) {
            totalSupply -= value;
        } else {
            balanceOf[to] += value;
        }
        emit Transfer(from, to, value);
    }

    function _execSwapBack(uint256 devAmt, uint256 lpAmt) internal {
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = wbnb;

        uint256 owed;
        if (minterSupply > burnedLocked + claimedTotal) owed = minterSupply - burnedLocked - claimedTotal;
        if (balanceOf[address(this)] < owed + devAmt + lpAmt) revert Forbidden();

        if (devAmt > 0) {
            allowance[address(this)][router] = devAmt;
            emit Approval(address(this), router, devAmt);
            IPancakeRouter(router).swapExactTokensForETHSupportingFeeOnTransferTokens(devAmt, 0, path, devWallet, block.timestamp);
        }

        if (lpAmt >= minUnit * 2) {
            uint256 half = lpAmt / 2;
            uint256 other = lpAmt - half;
            uint256 beforeBal = address(this).balance;
            allowance[address(this)][router] = half;
            emit Approval(address(this), router, half);
            IPancakeRouter(router).swapExactTokensForETHSupportingFeeOnTransferTokens(half, 0, path, address(this), block.timestamp);
            uint256 gained = address(this).balance - beforeBal;
            if (gained > 0 && other > 0) {
                allowance[address(this)][router] = other;
                emit Approval(address(this), router, other);
                IPancakeRouter(router).addLiquidityETH{value: gained}(address(this), other, 0, 0, DEAD, block.timestamp);
            }
        }
        emit SwapBack(devAmt, lpAmt);
    }

    function _swapBack() internal {
        if (inSwap || pair == address(0)) return;
        uint256 devAmt = taxDevReserve;
        uint256 lpAmt = taxLpReserve;
        if (devAmt + lpAmt < swapThreshold) return;
        inSwap = true;
        try this.execSwapBack(devAmt, lpAmt) {
            taxDevReserve = 0;
            taxLpReserve = 0;
        } catch {}
        inSwap = false;
    }

    // -------------------------------------------------------------------------
    // Vesting / forfeit
    // -------------------------------------------------------------------------

    function _checkpoint() internal {
        if (!launched) return;
        if (block.number > lastCommitBlock) {
            if (liveNet > 0 && uint256(liveNet) > hwmNet) hwmNet = uint256(liveNet);
            lastCommitBlock = block.number;
        }
        if (block.timestamp >= openTime + forfeitWindow && earmark > 0) {
            _flushEarmark(true, address(0));
        }
        _releaseLocked();
    }

    function _releaseLocked() internal {
        if (pool == 0 || totalPoints == 0) return;
        uint256 base = initialPool - burnedLocked;
        uint256 target = base * _fraction(hwmNet) / PREC;
        if (target <= vestedOut) return;
        uint256 delta = target - vestedOut;
        if (delta > pool) delta = pool;
        uint256 per = delta * PREC / totalPoints;
        if (per == 0) {
            if (_fraction(hwmNet) == PREC) _burnPoolDust();
            return;
        }
        uint256 credited = per * totalPoints / PREC;
        accVest += per;
        pool -= credited;
        vestedOut += credited;
        if (pool > 0 && _fraction(hwmNet) == PREC) _burnPoolDust();
    }

    function _burnPoolDust() internal {
        uint256 dust = pool;
        if (dust == 0) return;
        pool = 0;
        burnedLocked += dust;
        _move(address(this), address(0), dust);
    }

    function _fraction(uint256 hwm) internal view returns (uint256) {
        if (!launched || initialPool == 0) return 0;
        uint256 base = initialPool - burnedLocked;
        if (base == 0) return PREC;
        uint256 demandRel = hwm * demandNum / demandDen;
        uint256 demandFrac = demandRel >= base ? PREC : demandRel * PREC / base;
        uint256 timeFrac = _timeFraction(block.timestamp);
        return demandFrac > timeFrac ? demandFrac : timeFrac;
    }

    function _timeFraction(uint256 t) internal view returns (uint256) {
        uint256 start = openTime + vestCliff;
        if (t <= start) return 0;
        uint256 end = start + vestLinear;
        if (t >= end) return PREC;
        return (t - start) * PREC / vestLinear;
    }

    function _previewVest() internal view returns (uint256 acc, uint256 poolAfter) {
        acc = accVest;
        poolAfter = pool;
        if (!launched || totalPoints == 0 || poolAfter == 0) return (acc, poolAfter);
        uint256 h = previewHwm();
        uint256 base = initialPool - burnedLocked;
        uint256 frac = base == 0 ? PREC : 0;
        if (base > 0) {
            uint256 demandRel = h * demandNum / demandDen;
            uint256 demandFrac = demandRel >= base ? PREC : demandRel * PREC / base;
            uint256 timeFrac = _timeFraction(block.timestamp);
            frac = demandFrac > timeFrac ? demandFrac : timeFrac;
        }
        uint256 target = base * frac / PREC;
        if (target <= vestedOut) return (acc, poolAfter);
        uint256 delta = target - vestedOut;
        if (delta > poolAfter) delta = poolAfter;
        uint256 per = delta * PREC / totalPoints;
        if (per == 0) return (acc, poolAfter);
        uint256 credited = per * totalPoints / PREC;
        acc += per;
        poolAfter -= credited;
    }

    function _ensurePoints(address user) internal {
        Account storage a = accounts[user];
        if (!launched || a.shares == 0 || a.materialized) return;
        a.points = a.shares * lockedPerShare;
        a.materialized = true;
        a.claimable += a.shares * immediatePerShare;
    }

    function _crystallize(address user) internal {
        _ensurePoints(user);
        Account storage a = accounts[user];
        if (a.points == 0 && a.vestDebt == 0 && a.forfeitDebt == 0) return;
        uint256 vAcc = a.points * accVest / PREC;
        if (vAcc > a.vestDebt) a.claimable += vAcc - a.vestDebt;
        a.vestDebt = vAcc;
        uint256 fAcc = a.points * accForfeit / PREC;
        if (fAcc > a.forfeitDebt) a.forfeitedReceived += fAcc - a.forfeitDebt;
        a.forfeitDebt = fAcc;
    }

    function _lockedOf(address user) internal view returns (uint256) {
        Account storage a = accounts[user];
        if (!launched || totalPoints == 0) return 0;
        uint256 pts = a.materialized ? a.points : a.shares * lockedPerShare;
        if (pts == 0) return 0;
        return pts * pool / totalPoints;
    }

    /// @dev X% of liquid baseline, times rate(t), applied immediately into `earmark` so it cannot vest.
    ///      Dust below `minUnit` stays in `forfeitDust` (scaled) until it crosses `minUnit`.
    function _noteSale(address user, uint256 amount) internal {
        Account storage a = accounts[user];
        if (a.shares == 0 || amount == 0) return;

        if (block.timestamp >= openTime + forfeitWindow) {
            if (a.liquidBaseline > 0) {
                uint256 soldAll = amount > a.liquidBaseline ? a.liquidBaseline : amount;
                a.liquidBaseline -= soldAll;
            }
            a.forfeitDust = 0;
            return;
        }

        _ensurePoints(user);
        _crystallize(user);
        _pullForfeit(user);

        uint256 baseline = a.liquidBaseline;
        if (baseline == 0) return;
        uint256 soldAmt = amount > baseline ? baseline : amount;
        uint256 rate = forfeitRateAt(block.timestamp);
        a.liquidBaseline = baseline - soldAmt;
        if (rate == 0) return;

        uint256 locked = _lockedOf(user);
        if (locked == 0) return;
        // addScaled = locked * (soldAmt / baseline) * rate   (wei * 1e18)
        uint256 addScaled = FullMath.mulDiv(locked * rate, soldAmt, baseline);
        a.forfeitDust += addScaled;
        _pullForfeit(user);
    }

    function _pullForfeit(address user) internal {
        Account storage a = accounts[user];
        // Park every owed wei immediately so a split sale cannot vest it away or count it twice.
        // `minUnit` batches the redistribution (see `_flushEarmark`), it does not delay the penalty.
        uint256 rawWei = a.forfeitDust / PREC;
        if (rawWei == 0) return;
        uint256 parked = _park(user, rawWei);
        if (parked == 0) return;
        a.forfeitDust -= parked * PREC;
        _flushEarmark(false, user);
    }

    function _park(address user, uint256 amt) internal returns (uint256 parked) {
        Account storage a = accounts[user];
        uint256 locked = _lockedOf(user);
        if (amt == 0 || locked == 0 || a.points == 0 || totalPoints == 0) return 0;
        if (amt > locked) amt = locked;
        if (amt == 0) return 0;
        uint256 pointsRemove = amt == locked ? a.points : a.points * amt / locked;
        if (pointsRemove == 0) return 0;
        a.points -= pointsRemove;
        totalPoints -= pointsRemove;
        pool -= amt;
        a.vestDebt = a.points * accVest / PREC;
        a.forfeitDebt = a.points * accForfeit / PREC;
        a.forfeitedOut += amt;
        earmark += amt;
        parked = amt;
    }

    /// @param all When true, flush every wei (day-14 backstop). Otherwise flush `minUnit` chunks.
    /// @param exclude Seller to test "anyone else still locked". If they are the only holder, burn.
    function _flushEarmark(bool all, address exclude) internal {
        uint256 amt = all ? earmark : (earmark / minUnit) * minUnit;
        if (amt == 0) return;

        uint256 others = totalPoints;
        if (exclude != address(0) && totalPoints >= accounts[exclude].points) {
            others = totalPoints - accounts[exclude].points;
        }
        if (others == 0 || totalPoints == 0) {
            earmark -= amt;
            burnedLocked += amt;
            _move(address(this), address(0), amt);
            emit Forfeited(exclude, amt, 0, amt);
            return;
        }

        uint256 per = amt * PREC / totalPoints;
        if (per == 0) {
            earmark -= amt;
            burnedLocked += amt;
            _move(address(this), address(0), amt);
            emit Forfeited(exclude, amt, 0, amt);
            return;
        }
        uint256 credited = per * totalPoints / PREC;
        uint256 dust = amt - credited;
        earmark -= amt;
        pool += credited;
        accForfeit += per;
        if (dust > 0) {
            burnedLocked += dust;
            _move(address(this), address(0), dust);
        }
        emit Forfeited(exclude, amt, credited, dust);
    }

    // -------------------------------------------------------------------------
    // Quotes / gates
    // -------------------------------------------------------------------------

    function _cost(uint256 cursor, uint256 shares) internal view returns (uint256 cost) {
        uint256 left = shares;
        if (cursor < tier1End && left > 0) {
            uint256 n = tier1End - cursor;
            if (n > left) n = left;
            cost += n * tier1Price;
            cursor += n;
            left -= n;
        }
        if (cursor < tier2End && left > 0) {
            uint256 n = tier2End - cursor;
            if (n > left) n = left;
            cost += n * tier2Price;
            cursor += n;
            left -= n;
        }
        if (left > 0) cost += left * tier3Price;
    }

    function _tierAt(uint256 cursor) internal view returns (uint8 tier, uint256 price) {
        if (cursor < tier1End) return (1, tier1Price);
        if (cursor < tier2End) return (2, tier2Price);
        return (3, tier3Price);
    }

    /// @dev EIP-7702 delegation designator is `0xef0100 || address` (23 bytes). Anything else with code is rejected.
    ///      A 23-byte account that merely copies the prefix can pass; that is the spec's allowance, not a hidden admin path.
    function _requireEoa(address account) internal view {
        uint256 size;
        assembly {
            size := extcodesize(account)
        }
        if (size == 0) return;
        if (size != 23) revert ContractCallerNotAllowed(account);
        bytes memory code = account.code;
        if (code[0] != 0xef || code[1] != 0x01 || code[2] != 0x00) revert ContractCallerNotAllowed(account);
    }
}
