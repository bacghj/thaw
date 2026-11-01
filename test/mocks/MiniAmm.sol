// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Local Pancake V2 stand-in: 0.25% fee, skim/sync/mint/swap match the real pair closely enough
///         to test seeding and fee-on-transfer sells. Fork tests still hit the real router.
interface IERC20Mini {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

contract MiniWBNB {
    mapping(address => uint256) public balanceOf;
    string public name = "Wrapped BNB";
    string public symbol = "WBNB";
    uint8 public decimals = 18;

    event Transfer(address indexed from, address indexed to, uint256 value);

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
        emit Transfer(address(0), msg.sender, msg.value);
    }

    function withdraw(uint256 wad) external {
        require(balanceOf[msg.sender] >= wad, "WBNB");
        balanceOf[msg.sender] -= wad;
        emit Transfer(msg.sender, address(0), wad);
        (bool ok,) = msg.sender.call{value: wad}("");
        require(ok, "WBNB_SEND");
    }

    function transfer(address to, uint256 value) external returns (bool) {
        require(balanceOf[msg.sender] >= value, "WBNB");
        balanceOf[msg.sender] -= value;
        balanceOf[to] += value;
        emit Transfer(msg.sender, to, value);
        return true;
    }

    receive() external payable {
        balanceOf[msg.sender] += msg.value;
        emit Transfer(address(0), msg.sender, msg.value);
    }
}

contract MiniPair {
    address public token0;
    address public token1;
    uint112 private reserve0;
    uint112 private reserve1;
    uint32 private blockTimestampLast;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    uint256 private unlocked = 1;

    error Locked();

    modifier lock() {
        if (unlocked != 1) revert Locked();
        unlocked = 0;
        _;
        unlocked = 1;
    }

    function initialize(address a, address b) external {
        require(token0 == address(0), "init");
        (token0, token1) = a < b ? (a, b) : (b, a);
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, blockTimestampLast);
    }

    function mint(address to) external lock returns (uint256 liquidity) {
        uint256 bal0 = IERC20Mini(token0).balanceOf(address(this));
        uint256 bal1 = IERC20Mini(token1).balanceOf(address(this));
        uint256 amount0 = bal0 - reserve0;
        uint256 amount1 = bal1 - reserve1;
        if (totalSupply == 0) {
            liquidity = _sqrt(amount0 * amount1) - 1000;
            _mint(address(0), 1000);
        } else {
            uint256 l0 = amount0 * totalSupply / reserve0;
            uint256 l1 = amount1 * totalSupply / reserve1;
            liquidity = l0 < l1 ? l0 : l1;
        }
        require(liquidity > 0, "liq");
        _mint(to, liquidity);
        _update(bal0, bal1);
    }

    function skim(address to) external lock {
        uint256 bal0 = IERC20Mini(token0).balanceOf(address(this));
        uint256 bal1 = IERC20Mini(token1).balanceOf(address(this));
        _safe(token0, to, bal0 - reserve0);
        _safe(token1, to, bal1 - reserve1);
    }

    function sync() external lock {
        _update(IERC20Mini(token0).balanceOf(address(this)), IERC20Mini(token1).balanceOf(address(this)));
    }

    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata) external lock {
        require(amount0Out > 0 || amount1Out > 0, "out");
        require(amount0Out < reserve0 && amount1Out < reserve1, "liq");
        if (amount0Out > 0) _safe(token0, to, amount0Out);
        if (amount1Out > 0) _safe(token1, to, amount1Out);
        uint256 bal0 = IERC20Mini(token0).balanceOf(address(this));
        uint256 bal1 = IERC20Mini(token1).balanceOf(address(this));
        uint256 in0 = bal0 > reserve0 - amount0Out ? bal0 - (reserve0 - amount0Out) : 0;
        uint256 in1 = bal1 > reserve1 - amount1Out ? bal1 - (reserve1 - amount1Out) : 0;
        require(in0 > 0 || in1 > 0, "in");
        uint256 adj0 = bal0 * 10000 - in0 * 25;
        uint256 adj1 = bal1 * 10000 - in1 * 25;
        require(adj0 * adj1 >= uint256(reserve0) * uint256(reserve1) * (10000 ** 2), "k");
        _update(bal0, bal1);
    }

    function _mint(address to, uint256 value) internal {
        totalSupply += value;
        balanceOf[to] += value;
    }

    function _update(uint256 bal0, uint256 bal1) internal {
        reserve0 = uint112(bal0);
        reserve1 = uint112(bal1);
        blockTimestampLast = uint32(block.timestamp);
    }

    function _safe(address token, address to, uint256 value) internal {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(IERC20Mini.transfer.selector, to, value));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "transfer");
    }

    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}

contract MiniFactory {
    mapping(address => mapping(address => address)) public getPair;

    function createPair(address a, address b) external returns (address pair) {
        require(a != b && a != address(0) && b != address(0), "addr");
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        require(getPair[t0][t1] == address(0), "exists");
        MiniPair p = new MiniPair();
        p.initialize(t0, t1);
        pair = address(p);
        getPair[t0][t1] = pair;
        getPair[t1][t0] = pair;
    }
}

contract MiniRouter {
    address public immutable factory;
    address public immutable WETH;
    /// @notice Portion of addLiquidityETH inputs that are actually deposited, in bps.
    ///         10000 matches a router that consumes the full amount. Lower values refund the rest.
    uint256 public liquidityTokenBps = 10_000;
    uint256 public liquidityEthBps = 10_000;

    constructor(address factory_, address weth_) {
        factory = factory_;
        WETH = weth_;
    }

    receive() external payable {}

    function swapExactETHForTokens(uint256 amountOutMin, address[] calldata path, address to, uint256 deadline)
        external
        payable
        returns (uint256[] memory amounts)
    {
        require(deadline >= block.timestamp && path[0] == WETH && path.length == 2, "path");
        MiniWBNB(payable(WETH)).deposit{value: msg.value}();
        address pair = MiniFactory(factory).getPair(path[0], path[1]);
        require(MiniWBNB(payable(WETH)).transfer(pair, msg.value), "w");
        amounts = new uint256[](2);
        amounts[0] = msg.value;
        amounts[1] = _amountOut(path, pair, msg.value);
        require(amounts[1] >= amountOutMin, "slip");
        _swap(pair, path, amounts[1], to);
    }

    function swapExactTokensForETH(uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256 deadline)
        external
        returns (uint256[] memory amounts)
    {
        require(deadline >= block.timestamp && path[1] == WETH && path.length == 2, "path");
        address pair = MiniFactory(factory).getPair(path[0], path[1]);
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = _amountOut(path, pair, amountIn);
        require(amounts[1] >= amountOutMin, "slip");
        require(IERC20Mini(path[0]).transferFrom(msg.sender, pair, amountIn), "pull");
        _swap(pair, path, amounts[1], address(this));
        MiniWBNB(payable(WETH)).withdraw(amounts[1]);
        (bool ok,) = to.call{value: amounts[1]}("");
        require(ok, "eth");
    }

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external {
        require(deadline >= block.timestamp && path[1] == WETH && path.length == 2, "path");
        address pair = MiniFactory(factory).getPair(path[0], path[1]);
        require(IERC20Mini(path[0]).transferFrom(msg.sender, pair, amountIn), "pull");
        uint256 outAmt = _supportingOut(pair, path);
        require(outAmt >= amountOutMin, "slip");
        _swap(pair, path, outAmt, address(this));
        MiniWBNB(payable(WETH)).withdraw(outAmt);
        (bool ok,) = to.call{value: outAmt}("");
        require(ok, "eth");
    }

    function setLiquidityUse(uint256 tokenBps, uint256 ethBps) external {
        require(tokenBps > 0 && tokenBps <= 10_000 && ethBps > 0 && ethBps <= 10_000, "bps");
        liquidityTokenBps = tokenBps;
        liquidityEthBps = ethBps;
    }

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256,
        uint256,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity) {
        require(deadline >= block.timestamp, "time");
        amountToken = amountTokenDesired * liquidityTokenBps / 10_000;
        amountETH = msg.value * liquidityEthBps / 10_000;
        require(amountToken > 0 && amountETH > 0, "dust");
        MiniWBNB(payable(WETH)).deposit{value: amountETH}();
        if (msg.value > amountETH) {
            (bool refunded,) = msg.sender.call{value: msg.value - amountETH}("");
            require(refunded, "refund");
        }
        address pair = MiniFactory(factory).getPair(token, WETH);
        require(IERC20Mini(token).transferFrom(msg.sender, pair, amountToken), "pull");
        require(MiniWBNB(payable(WETH)).transfer(pair, amountETH), "w");
        liquidity = MiniPair(pair).mint(to);
    }

    function _swap(address pair, address[] calldata path, uint256 amountOut, address to) internal {
        bool token0IsIn = MiniPair(pair).token0() == path[0];
        uint256 out0 = token0IsIn ? 0 : amountOut;
        uint256 out1 = token0IsIn ? amountOut : 0;
        MiniPair(pair).swap(out0, out1, to, "");
    }

    function _amountOut(address[] calldata path, address pair, uint256 amountIn) internal view returns (uint256) {
        (uint112 r0, uint112 r1,) = MiniPair(pair).getReserves();
        bool inIs0 = MiniPair(pair).token0() == path[0];
        uint256 reserveIn = inIs0 ? uint256(r0) : uint256(r1);
        uint256 reserveOut = inIs0 ? uint256(r1) : uint256(r0);
        uint256 amountInWithFee = amountIn * 9975;
        return (amountInWithFee * reserveOut) / (reserveIn * 10000 + amountInWithFee);
    }

    function _supportingOut(address pair, address[] calldata path) internal view returns (uint256) {
        (uint112 r0, uint112 r1,) = MiniPair(pair).getReserves();
        bool inIs0 = MiniPair(pair).token0() == path[0];
        uint256 reserveIn = inIs0 ? uint256(r0) : uint256(r1);
        uint256 reserveOut = inIs0 ? uint256(r1) : uint256(r0);
        uint256 balIn = IERC20Mini(path[0]).balanceOf(pair);
        uint256 amountIn = balIn - reserveIn;
        uint256 amountInWithFee = amountIn * 9975;
        return (amountInWithFee * reserveOut) / (reserveIn * 10000 + amountInWithFee);
    }
}
