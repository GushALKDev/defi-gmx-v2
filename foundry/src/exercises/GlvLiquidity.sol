// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console} from "forge-std/Test.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {IGlvRouter} from "../interfaces/IGlvRouter.sol";
import {GlvDepositUtils} from "../types/GlvDepositUtils.sol";
import {GlvWithdrawalUtils} from "../types/GlvWithdrawalUtils.sol";
import "../Constants.sol";

contract GlvLiquidity {
    IERC20 constant weth = IERC20(WETH);
    IERC20 constant usdc = IERC20(USDC);
    IERC20 constant glvToken = IERC20(GLV_TOKEN_WETH_USDC);
    IGlvRouter constant glvRouter = IGlvRouter(GLV_ROUTER);

    // Task 1 - Receive execution fee refund from GMX

    receive() external payable {}

    // Task 2 - Create an order to deposit USDC into GLV vault
    function createGlvDeposit(uint256 usdcAmount, uint256 minGlvAmount)
        external
        payable
        returns (bytes32 key)
    {
        uint256 executionFee = 0.1 * 1e18;
        usdc.transferFrom(msg.sender, address(this), usdcAmount);

        // Task 2.1 - Send execution fee to GLV vault

        glvRouter.sendWnt{value: executionFee}({
            receiver: GLV_VAULT,
            amount: executionFee
        });

        // Task 2.2 - Send USDC to GLV vault
        usdc.approve(ROUTER, usdcAmount);
        glvRouter.sendTokens({
            token: USDC,
            receiver: GLV_VAULT,
            amount: usdcAmount
        });

        // Task 2.3 - Create an order to deposit USDC

        return glvRouter.createGlvDeposit(
            GlvDepositUtils.CreateGlvDepositParams({
                glv: GLV_TOKEN_WETH_USDC,
                market: GM_TOKEN_ETH_WETH_USDC,
                receiver: address(this),
                callbackContract: address(this),
                uiFeeReceiver: address(this),
                initialLongToken: WETH,
                initialShortToken: USDC,
                longTokenSwapPath: new address[](0),
                shortTokenSwapPath: new address[](0),
                minGlvTokens: minGlvAmount,
                executionFee: executionFee,
                callbackGasLimit: 100000,
                shouldUnwrapNativeToken: false,
                isMarketTokenDeposit: false
            })
        );
    }

    // Task 3 - Create an order to withdraw liquidity
    function createGlvWithdrawal(uint256 minWethAmount, uint256 minUsdcAmount)
        external
        payable
        returns (bytes32 key)
    {
        uint256 executionFee = 0.1 * 1e18;

        // 3.1 Send execution fee to GLV vault
        glvRouter.sendWnt{value: executionFee}({
            receiver: GLV_VAULT,
            amount: executionFee
        });

        // 3.2 - Send GLV Tokens to GLV vault
        uint256 glvTokenAmount = glvToken.balanceOf(address(this));
        glvToken.approve(ROUTER, glvTokenAmount);
        glvRouter.sendTokens({
            token: address(glvToken),
            receiver: GLV_VAULT,
            amount: glvTokenAmount
        });

        // 3.3 Create an order to withdraw liquidity

        return glvRouter.createGlvWithdrawal(
            GlvWithdrawalUtils.CreateGlvWithdrawalParams({
                receiver: address(this),
                callbackContract: address(this),
                uiFeeReceiver: address(this),
                market: GM_TOKEN_ETH_WETH_USDC,
                glv: GLV_TOKEN_WETH_USDC,
                longTokenSwapPath: new address[](0),
                shortTokenSwapPath: new address[](0),
                minLongTokenAmount: minWethAmount,
                minShortTokenAmount: minUsdcAmount,
                shouldUnwrapNativeToken: false,
                executionFee: executionFee,
                callbackGasLimit: 100000
            })
        );
    }
}
