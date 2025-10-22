// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console} from "forge-std/Test.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {IExchangeRouter} from "../interfaces/IExchangeRouter.sol";
import {Order} from "../types/Order.sol";
import {IBaseOrderUtils} from "../types/IBaseOrderUtils.sol";
import {Oracle} from "../lib/Oracle.sol";
import "../Constants.sol";

contract TakeProfitAndStopLoss {
    IERC20 constant weth = IERC20(WETH);
    IERC20 constant usdc = IERC20(USDC);
    IExchangeRouter constant exchangeRouter = IExchangeRouter(EXCHANGE_ROUTER);
    Oracle immutable oracle;

    constructor(address _oracle) {
        oracle = Oracle(_oracle);
    }

    // Task 1 - Receive execution fee refund from GMX

    receive() external payable {}

    // Task 2 - Create orders to
    // 1. Long ETH with USDC collateral
    // 2. Stop loss for ETH price below 90% of current price
    // 3. Take profit for ETH price above 110% of current price
    function createTakeProfitAndStopLossOrders(
        uint256 leverage,
        uint256 usdcAmount
    ) external payable returns (bytes32[] memory keys) {
        uint256 executionFee = 0.1 * 1e18;
        usdc.transferFrom(msg.sender, address(this), usdcAmount);
        
        keys = new bytes32[](3);
        
        // Task 2.1 - Send execution fee to the order vault
        exchangeRouter.sendWnt{value: executionFee}({
            receiver: ORDER_VAULT,
            amount: executionFee
        });

        // Task 2.2 - Send USDC to the order vault
        usdc.approve(ROUTER, usdcAmount);
        exchangeRouter.sendTokens({
            token: USDC,
            receiver: ORDER_VAULT,
            amount: usdcAmount
        });

        // Task 2.3 - Create a long order to long ETH with USDC collateral
        // 1 USD = 1e8
        uint256 usdcPrice = oracle.getPrice(CHAINLINK_USDC_USD);

        // 1 USD = 1e30
        uint256 sizeDeltaUsd = leverage * usdcAmount * usdcPrice * 1e16; // 1e0 * 1e6 * 1e8 * 1e16 = 1e30
        
        // executionPrice < acceptablePrice for long
        uint256 ethPrice = oracle.getPrice(CHAINLINK_ETH_USD); // 8 decimals
        uint256 acceptablePrice = ethPrice * 1e4 * 110 / 100; // 10% slippage with 12 decimals

        keys[0] = exchangeRouter.createOrder(
            IBaseOrderUtils.CreateOrderParams({
                addresses: IBaseOrderUtils.CreateOrderParamsAddresses({
                    receiver: address(this),
                    cancellationReceiver: address(0),
                    callbackContract: address(0),
                    uiFeeReceiver: address(0),
                    market: GM_TOKEN_ETH_WETH_USDC,
                    initialCollateralToken: USDC,
                    swapPath: new address[](0)
                }),
                numbers: IBaseOrderUtils.CreateOrderParamsNumbers({
                    sizeDeltaUsd: sizeDeltaUsd,
                    initialCollateralDeltaAmount: 0,
                    triggerPrice: 0,
                    acceptablePrice: acceptablePrice,
                    executionFee: executionFee,
                    callbackGasLimit: 0,
                    minOutputAmount: 0,
                    validFromTime: 0
                }),
                orderType: Order.OrderType.MarketIncrease,
                decreasePositionSwapType: Order.DecreasePositionSwapType.NoSwap,
                isLong: true,
                shouldUnwrapNativeToken: false,
                autoCancel: false,
                referralCode: bytes32(uint256(0))
            })
        );

        // Task 2.4 - Send execution fee to the order vault
        exchangeRouter.sendWnt{value: executionFee}({
            receiver: ORDER_VAULT,
            amount: executionFee
        });

        // Task 2.5 - Create a stop loss for 90% of current ETH price
        uint256 stopLossPrice = ethPrice * 1e4 * 90 / 100; // 10% below current price with 12 decimals

        keys[1] = exchangeRouter.createOrder(
            IBaseOrderUtils.CreateOrderParams({
                addresses: IBaseOrderUtils.CreateOrderParamsAddresses({
                    receiver: address(this),
                    cancellationReceiver: address(0),
                    callbackContract: address(0),
                    uiFeeReceiver: address(0),
                    market: GM_TOKEN_ETH_WETH_USDC,
                    initialCollateralToken: USDC,
                    swapPath: new address[](0)
                }),
                numbers: IBaseOrderUtils.CreateOrderParamsNumbers({
                    sizeDeltaUsd: sizeDeltaUsd,
                    initialCollateralDeltaAmount: usdcAmount,
                    triggerPrice: stopLossPrice,
                    acceptablePrice: 0,
                    executionFee: executionFee,
                    callbackGasLimit: 0,
                    minOutputAmount: 0,
                    validFromTime: block.timestamp
                }),
                orderType: Order.OrderType.StopLossDecrease,
                decreasePositionSwapType: Order.DecreasePositionSwapType.NoSwap,
                isLong: true,
                shouldUnwrapNativeToken: false,
                autoCancel: true,
                referralCode: bytes32(uint256(0))
            })
        );

        // Task 2.6 - Send execution fee to the order vault
        exchangeRouter.sendWnt{value: executionFee}({
            receiver: ORDER_VAULT,
            amount: executionFee
        });

        // Task 2.7 - Create an order to take profit above 110% of current price
        uint256 takeProfitPrice = ethPrice * 1e4 * 110 / 100; // 10% above current price with 12 decimals
        uint256 takeProfitAcceptablePrice = ethPrice * 1e4 * 99 / 100;
        
        keys[2] = exchangeRouter.createOrder(
            IBaseOrderUtils.CreateOrderParams({
                addresses: IBaseOrderUtils.CreateOrderParamsAddresses({
                    receiver: address(this),
                    cancellationReceiver: address(0),
                    callbackContract: address(0),
                    uiFeeReceiver: address(0),
                    market: GM_TOKEN_ETH_WETH_USDC,
                    initialCollateralToken: USDC,
                    swapPath: new address[](0)
                }),
                numbers: IBaseOrderUtils.CreateOrderParamsNumbers({
                    sizeDeltaUsd: sizeDeltaUsd,
                    initialCollateralDeltaAmount: usdcAmount,
                    triggerPrice: takeProfitPrice,
                    acceptablePrice: takeProfitAcceptablePrice,
                    executionFee: executionFee,
                    callbackGasLimit: 0,
                    minOutputAmount: 0,
                    validFromTime: block.timestamp
                }),
                orderType: Order.OrderType.LimitDecrease,
                decreasePositionSwapType: Order.DecreasePositionSwapType.SwapPnlTokenToCollateralToken,
                isLong: true,
                shouldUnwrapNativeToken: false,
                autoCancel: true,
                referralCode: bytes32(uint256(0))
            })
        );
    }
}
