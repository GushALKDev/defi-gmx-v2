// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console} from "forge-std/Test.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {IExchangeRouter} from "../interfaces/IExchangeRouter.sol";
import {IReader} from "../interfaces/IReader.sol";
import {Order} from "../types/Order.sol";
import {IBaseOrderUtils} from "../types/IBaseOrderUtils.sol";
import "../Constants.sol";

contract LimitSwap {
    IERC20 constant weth = IERC20(WETH);
    IERC20 constant usdc = IERC20(USDC);
    IExchangeRouter constant exchangeRouter = IExchangeRouter(EXCHANGE_ROUTER);

    // Task 1 - Receive execution fee refund from GMX

    receive() external payable {}

    // Task 2 - Create a limit order to swap USDC to WETH
    function createLimitOrder(uint256 usdcAmount, uint256 maxEthPrice)
        external
        payable
        returns (bytes32 key)
    {
        uint256 executionFee = 0.1 * 1e18;
        usdc.transferFrom(msg.sender, address(this), usdcAmount);

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

        // Task 2.3 - Create an order to swap USDC to WETH
        // usdcAmount = 1e6
        // ETH amount = 1e18
        // 18 decimals - 6 decimals = 12 decimals
        // maxEthPrice = 1e8 --> From Chainlink oracle
        // minOutputAmount = (usdcAmount * 1e20) / maxEthPrice;
        // minOutputAmount: uint256 = (1e6 * x) / 1e8 = 1e18
        // x = (1e18 * 1e8) / 1e6 = 1e20
        // minOutputAmount: uint256 = (1e6 * 1e20) / 1e8 = 1e18
        uint256 minOutputAmount = (usdcAmount * 1e20) / maxEthPrice;

        address[] memory swapPath = new address[](1);
        swapPath[0] = GM_TOKEN_ETH_WETH_USDC;

        return exchangeRouter.createOrder(
            IBaseOrderUtils.CreateOrderParams({
                addresses: IBaseOrderUtils.CreateOrderParamsAddresses({
                    receiver: address(this),
                    cancellationReceiver: address(0),
                    callbackContract: address(0),
                    uiFeeReceiver: address(0),
                    market: address(0),
                    initialCollateralToken: USDC,
                    swapPath: swapPath
                }),
                numbers: IBaseOrderUtils.CreateOrderParamsNumbers({
                    sizeDeltaUsd: 0,
                    initialCollateralDeltaAmount: 0,
                    triggerPrice: 0,
                    acceptablePrice: 0,
                    executionFee: executionFee,
                    callbackGasLimit: 0,
                    minOutputAmount: minOutputAmount,
                    validFromTime: 0
                }),
                orderType: Order.OrderType.LimitSwap,
                decreasePositionSwapType: Order.DecreasePositionSwapType.NoSwap,
                isLong: false,
                shouldUnwrapNativeToken: false,
                autoCancel: false,
                referralCode: bytes32(uint256(0))
            })
        );
    }
}
