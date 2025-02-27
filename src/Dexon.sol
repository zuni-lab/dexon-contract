// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { ISwapRouter } from "./externals/uniswapV3/interfaces/ISwapRouter.sol";
import { IUniswapV3Pool } from "./externals/uniswapV3/interfaces/IUniswapV3Pool.sol";
import { OracleLibrary } from "./externals/uniswapV3/libraries/OracleLibrary.sol";
import { Path } from "./externals/uniswapV3/libraries/Path.sol";
import { PoolAddress } from "./externals/uniswapV3/libraries/PoolAddress.sol";

contract Dexon is EIP712 {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    string public constant NAME = "Dexon";
    string public constant VERSION = "1";

    address public constant UNISWAP_V3_FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
    address public constant UNISWAP_V3_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address public constant WETH_USDC_POOL = 0xd0b53D9277642d899DF5C87A3966A349A798F224;

    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant WETH = 0x4200000000000000000000000000000000000006;

    uint256 public constant ONE_HUNDRED_PERCENT = 1e6;

    bytes32 public constant ORDER_TYPEHASH = keccak256(
        "Order(address account,bytes path,uint256 amount,uint256 triggerPrice,uint256 slippage,uint8 orderType,uint8 orderSide,uint256 deadline)" // solhint-disable-line
    );

    uint256 private constant _PRICE_SCALE = 1e18;

    enum OrderType {
        STOP_ORDER,
        LIMIT_ORDER
    }

    enum OrderSide {
        BUY,
        SELL
    }

    struct Order {
        address account;
        bytes path;
        uint256 amount;
        // Price in USDC (18 decimals)
        uint256 triggerPrice;
        // 100 = 0.01%
        uint256 slippage;
        OrderType orderType;
        OrderSide orderSide;
        uint256 deadline;
        bytes signature;
    }

    event OrderExecuted(
        bytes32 indexed orderId,
        address indexed account,
        bytes path,
        uint256 amount,
        uint256 triggerPrice,
        uint256 slippage,
        OrderType orderType,
        OrderSide orderSide
    );

    constructor() EIP712(NAME, VERSION) { }

    function executeOrder(bytes32 orderId, Order memory order) public {
        (address tokenIn, address tokenOut) = _validatePath(order.orderSide, order.path);

        _validateTriggerCondition(order);
        _validateSignature(order);

        IERC20(tokenIn).safeTransferFrom(order.account, address(this), order.amount);
        IERC20(tokenIn).approve(UNISWAP_V3_ROUTER, order.amount);

        uint256 tokenInDecimals = IERC20Metadata(tokenIn).decimals();
        uint256 tokenOutDecimals = IERC20Metadata(tokenOut).decimals();

        uint256 scaledAmountOut = Math.mulDiv(order.amount, order.triggerPrice, 10 ** tokenInDecimals);
        uint256 amountOut = Math.mulDiv(scaledAmountOut, 10 ** tokenOutDecimals, _PRICE_SCALE);
        uint256 amountOutMinimum = Math.mulDiv(amountOut, ONE_HUNDRED_PERCENT - order.slippage, ONE_HUNDRED_PERCENT);

        ISwapRouter.ExactInputParams memory params = ISwapRouter.ExactInputParams({
            path: order.path,
            recipient: order.account,
            deadline: order.deadline,
            amountIn: order.amount,
            amountOutMinimum: amountOutMinimum
        });
        ISwapRouter(UNISWAP_V3_ROUTER).exactInput(params);

        emit OrderExecuted(
            orderId,
            order.account,
            order.path,
            order.amount,
            order.triggerPrice,
            order.slippage,
            order.orderType,
            order.orderSide
        );
    }

    function getTokenPriceOnUsdc(bytes memory path) public view returns (uint256) {
        (address tokenA, address tokenB, uint24 fee) = Path.decodeFirstPool(path);
        uint256 tokenPriceOnUsdc;
        if (tokenA == USDC || tokenB == USDC) {
            address baseToken = tokenA == USDC ? tokenB : tokenA;
            tokenPriceOnUsdc = _getQuote(
                IUniswapV3Pool(
                    PoolAddress.computeAddress(UNISWAP_V3_FACTORY, PoolAddress.getPoolKey(tokenA, tokenB, fee))
                ),
                baseToken,
                USDC
            );
        } else {
            address baseToken = tokenA == WETH ? tokenB : tokenA;
            uint256 tokenPriceOnEth = _getQuote(
                IUniswapV3Pool(
                    PoolAddress.computeAddress(UNISWAP_V3_FACTORY, PoolAddress.getPoolKey(tokenA, tokenB, fee))
                ),
                baseToken,
                WETH
            );
            uint256 ethPriceOnUsdc = _getQuote(IUniswapV3Pool(WETH_USDC_POOL), WETH, USDC);
            tokenPriceOnUsdc = Math.mulDiv(tokenPriceOnEth, ethPriceOnUsdc, _PRICE_SCALE);
        }

        return tokenPriceOnUsdc;
    }

    function _validatePath(
        OrderSide orderSide,
        bytes memory path
    )
        internal
        pure
        returns (address tokenIn, address tokenOut)
    {
        uint256 numPools = Path.numPools(path);
        require(numPools <= 2, "Invalid path");

        if (numPools == 1) {
            (tokenIn, tokenOut,) = Path.decodeFirstPool(path);
        } else {
            address midToken;

            (tokenIn, midToken,) = Path.decodeFirstPool(path);
            require(midToken == WETH, "Not supported mid token");

            (midToken, tokenOut,) = Path.decodeFirstPool(Path.skipToken(path));
        }

        if (orderSide == OrderSide.SELL) {
            require(tokenOut == USDC, "Not supported token");
        } else {
            require(tokenIn == USDC, "Not supported token");
        }
    }

    function _validateTriggerCondition(Order memory order) internal view {
        uint256 currentPrice = getTokenPriceOnUsdc(order.path);
        if (order.orderType == OrderType.STOP_ORDER) {
            if (order.orderSide == OrderSide.BUY) {
                if (currentPrice >= order.triggerPrice) {
                    return;
                }
            } else {
                if (currentPrice <= order.triggerPrice) {
                    return;
                }
            }
        } else {
            if (order.orderSide == OrderSide.BUY) {
                if (currentPrice <= order.triggerPrice) {
                    return;
                }
            } else {
                if (currentPrice >= order.triggerPrice) {
                    return;
                }
            }
        }

        revert("Price condition not met");
    }

    function _validateSignature(Order memory order) internal view {
        bytes32 structHash = keccak256(
            abi.encode(
                ORDER_TYPEHASH,
                order.account,
                order.path,
                order.amount,
                order.triggerPrice,
                order.slippage,
                order.orderType,
                order.orderSide,
                order.deadline
            )
        );
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, order.signature);
        require(signer == order.account, "Invalid signature");
    }

    function _getQuote(IUniswapV3Pool pool, address baseToken, address quoteToken) internal view returns (uint256) {
        IUniswapV3Pool.Slot0 memory slot0 = pool.slot0();
        int24 tick = slot0.tick;

        uint256 baseTokenDecimal = IERC20Metadata(baseToken).decimals();
        uint256 quoteTokenDecimal = IERC20Metadata(quoteToken).decimals();

        uint128 baseAmount = (10 ** baseTokenDecimal).toUint128();
        uint256 quoteAmount = OracleLibrary.getQuoteAtTick(tick, baseAmount, baseToken, quoteToken);

        return Math.mulDiv(quoteAmount, _PRICE_SCALE, 10 ** quoteTokenDecimal);
    }
}
