// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console} from "forge-std/Test.sol";
import {IERC20} from "../../interfaces/IERC20.sol";
import {Math} from "../../lib/Math.sol";
import {Auth} from "../../lib/app/Auth.sol";
import "../../Constants.sol";
import {GmxHelper} from "./GmxHelper.sol";

contract Strategy is Auth, GmxHelper {
    IERC20 public constant weth = IERC20(WETH);

    constructor(address oracle)
        GmxHelper(
            GM_TOKEN_ETH_WETH_USDC,
            WETH,
            USDC,
            CHAINLINK_ETH_USD,
            CHAINLINK_USDC_USD,
            oracle
        )
    {}

    receive() external payable {}

    // Task 1: Calculate total value managed by this contract in terms of WETH
    function totalValueInToken() external view returns (uint256) {
        uint256 value = weth.balanceOf(address(this));
        int256 currentCollateral = getPositionWithPnlInToken();

        if (currentCollateral >= 0) {
            value += uint256(currentCollateral);
        } else {
            // Reduce the value by the loss, but not below zero
            value -= Math.min(value, uint256(-currentCollateral));
        }

        return value;
    }

    // Task 2: Create market increase order
    function increase(uint256 wethAmount)
        external
        payable
        auth
        returns (bytes32 orderKey)
    {
        orderKey = createIncreaseShortPositionOrder({
            executionFee: msg.value,
            longTokenAmount: wethAmount
        });
    }

    // Task 3: Create market decrease order
    // Function call is from the vault when the callback contract is not address(0).
    function decrease(uint256 wethAmount, address callbackContract)
        external
        payable
        auth
        returns (bytes32 orderKey)
    {
        if (callbackContract == address(0)) {
            orderKey = createDecreaseShortPositionOrder({
                executionFee: msg.value,
                longTokenAmount: wethAmount,
                receiver: address(this),
                callbackContract: address(0),
                callbackGasLimit: 0
            });
        } else {
            uint256 maxCallbackGasLimit = getMaxCallbackGasLimit();
            require(msg.value >= maxCallbackGasLimit, "Insufficient execution fee");

            uint256 positionCollateralAmount = getPositionCollateralAmount();
            uint256 positionWithPnlInToken = uint256(getPositionWithPnlInToken());
            uint256 longTokenAmount = positionCollateralAmount * wethAmount / positionWithPnlInToken;

            orderKey = createDecreaseShortPositionOrder({
                executionFee: msg.value,
                longTokenAmount: longTokenAmount,
                receiver: callbackContract,
                callbackContract: callbackContract,
                callbackGasLimit: maxCallbackGasLimit
            });
        }
    }

    // Task 4: Cancel an order
    function cancel(bytes32 orderKey) external payable auth {
        cancelOrder(orderKey);
    }

    // Task 5: Claim funding fees
    function claim() external {
        claimFundingFees();
    }

    function transfer(address dst, uint256 amount) external auth {
        weth.transfer(dst, amount);
    }

    function withdraw(address token) external auth {
        if (token == address(0)) {
            (bool ok,) = msg.sender.call{value: address(this).balance}("");
            require(ok, "Send ETH failed");
        } else {
            IERC20(token).transfer(
                msg.sender, IERC20(token).balanceOf(address(this))
            );
        }
    }
}
