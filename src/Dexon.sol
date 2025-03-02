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

    address public constant UNISWAP_V3_FACTORY = 0x961235a9020B05C44DF1026D956D1F4D78014276;
    address public constant UNISWAP_V3_ROUTER = 0x4c4eABd5Fb1D1A7234A48692551eAECFF8194CA7;
    address public constant WETH_USDC_POOL = 0xb8bd80BA7aFA32006Ae4cF7D1dA2Ecb8bBCa9Bf8;

    address public constant USDC = 0x9f6006523bbe9D719E83a9f050108dD5463f269d;
    address public constant WETH = 0x951DbC0e23228A5b5A40f4B845Da75E5658Ba3E4;

    uint256 public constant ONE_HUNDRED_PERCENT = 1e6;

    bytes32 public constant ORDER_TYPEHASH = keccak256(
        "Order(address account,uint256 nonce,bytes path,uint256 amount,uint256 triggerPrice,uint256 slippage,uint8 orderType,uint8 orderSide,uint256 deadline)" // solhint-disable-line
    );

    uint256 private constant _PRICE_SCALE = 1e18;

    mapping(address account => mapping(uint256 nonce => bool used)) public nonces;

    enum OrderType {
        LIMIT_ORDER,
        STOP_ORDER
    }

    enum OrderSide {
        BUY,
        SELL
    }

    struct Order {
        address account;
        uint256 nonce;
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
        address indexed account,
        uint256 indexed nonce,
        bytes path,
        uint256 amount,
        uint256 triggerPrice,
        uint256 slippage,
        OrderType orderType,
        OrderSide orderSide
    );

    constructor() EIP712(NAME, VERSION) { }

    function executeOrder(Order memory order) public {
        (address tokenIn, address tokenOut) = _validatePath(order.orderSide, order.path);

        _useNonce(order.account, order.nonce);
        _validateDeadline(order.deadline);
        _validateTriggerCondition(order);
        _validateSignature(order);

        uint256 tokenInDecimals = IERC20Metadata(tokenIn).decimals();
        uint256 tokenOutDecimals = IERC20Metadata(tokenOut).decimals();

        if (order.orderSide == OrderSide.SELL) {
            IERC20(tokenIn).safeTransferFrom(order.account, address(this), order.amount);
            IERC20(tokenIn).approve(UNISWAP_V3_ROUTER, order.amount);

            uint256 scaledAmountOut = Math.mulDiv(order.amount, order.triggerPrice, 10 ** tokenInDecimals);
            uint256 amountOut = Math.mulDiv(scaledAmountOut, 10 ** tokenOutDecimals, _PRICE_SCALE);
            uint256 amountOutMinimum = Math.mulDiv(amountOut, ONE_HUNDRED_PERCENT - order.slippage, ONE_HUNDRED_PERCENT);

            ISwapRouter.ExactInputParams memory params = ISwapRouter.ExactInputParams({
                path: order.path,
                recipient: order.account,
                amountIn: order.amount,
                amountOutMinimum: amountOutMinimum
            });
            ISwapRouter(UNISWAP_V3_ROUTER).exactInput(params);
        } else {
            uint256 scaledAmountIn = Math.mulDiv(order.amount, order.triggerPrice, 10 ** tokenOutDecimals);
            uint256 amountIn = Math.mulDiv(scaledAmountIn, 10 ** tokenInDecimals, _PRICE_SCALE);
            uint256 amountInMaximum = Math.mulDiv(amountIn, ONE_HUNDRED_PERCENT + order.slippage, ONE_HUNDRED_PERCENT);

            IERC20(tokenIn).safeTransferFrom(order.account, address(this), amountInMaximum);
            IERC20(tokenIn).approve(UNISWAP_V3_ROUTER, type(uint256).max);

            ISwapRouter.ExactOutputParams memory params = ISwapRouter.ExactOutputParams({
                path: order.path,
                recipient: address(this),
                amountOut: order.amount,
                amountInMaximum: amountInMaximum
            });
            uint256 actualAmountIn = ISwapRouter(UNISWAP_V3_ROUTER).exactOutput(params);

            uint256 refundAmount = amountInMaximum - actualAmountIn;
            IERC20(tokenIn).safeTransfer(order.account, refundAmount);
        }

        emit OrderExecuted(
            order.account,
            order.nonce,
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

    function _useNonce(address account, uint256 nonce) internal {
        require(!nonces[account][nonce], "Used nonce");
        nonces[account][nonce] = true;
    }

    function _validateDeadline(uint256 deadline) internal view {
        require(block.timestamp <= deadline, "Expired order");
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

        bool isSell = orderSide == OrderSide.SELL;

        if (numPools == 1) {
            (tokenIn, tokenOut,) = Path.decodeFirstPool(path);
            if (!isSell) {
                (tokenIn, tokenOut) = (tokenOut, tokenIn);
            }
        } else {
            address midToken;
            if (isSell) {
                (tokenIn, midToken,) = Path.decodeFirstPool(path);
                (midToken, tokenOut,) = Path.decodeFirstPool(Path.skipToken(path));
            } else {
                (tokenOut, midToken,) = Path.decodeFirstPool(path);
                (midToken, tokenIn,) = Path.decodeFirstPool(Path.skipToken(path));
            }
            require(midToken == WETH, "Not supported mid token");
        }

        require(isSell ? tokenOut == USDC : tokenIn == USDC, "Not supported token");

        return (tokenIn, tokenOut);
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
                order.nonce,
                keccak256(order.path),
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
