// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console} from "forge-std/Test.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {IExchangeRouter} from "../interfaces/IExchangeRouter.sol";
import {IDataStore} from "../interfaces/IDataStore.sol";
import {IReader} from "../interfaces/IReader.sol";
import {Order} from "../types/Order.sol";
import {Market} from "../types/Market.sol";
import {MarketPoolValueInfo} from "../types/MarketPoolValueInfo.sol";
import {Price} from "../types/Price.sol";
import {DepositUtils} from "../types/DepositUtils.sol";
import {WithdrawalUtils} from "../types/WithdrawalUtils.sol";
import {Keys} from "../lib/Keys.sol";
import {Oracle} from "../lib/Oracle.sol";
import "../Constants.sol";

contract GmLiquidity {
    IERC20 constant weth = IERC20(WETH);
    IERC20 constant usdc = IERC20(USDC);
    IERC20 constant gmToken = IERC20(GM_TOKEN_BTC_WBTC_USDC);
    IExchangeRouter constant exchangeRouter = IExchangeRouter(EXCHANGE_ROUTER);
    IDataStore constant dataStore = IDataStore(DATA_STORE);
    IReader constant reader = IReader(READER);

    Oracle immutable oracle;

    constructor(address _oracle) {
        oracle = Oracle(_oracle);
    }

    // Task 1 - Receive execution fee refund from GMX

    receive() external payable {}

    // Task 2 - Get market token price
    function getMarketTokenPriceUsd() public view returns (uint256) {
        // 1 USD = 1e8
        uint256 btcPrice = oracle.getPrice(CHAINLINK_BTC_USD);

        console.log("BTC Price:", btcPrice);

        Price.Props memory indexTokenPrice = Price.Props({
            min: btcPrice * 1e30 / (1e8 * 1e8) * 99 / 100,
            max: btcPrice * 1e30 / (1e8 * 1e8) * 101 / 100
        });

        Price.Props memory longTokenPrice = Price.Props({
            min: btcPrice * 1e30 / (1e8 * 1e8) * 99 / 100,
            max: btcPrice * 1e30 / (1e8 * 1e8) * 101 / 100
        });

        Price.Props memory shortTokenPrice = Price.Props({
            min: 1 * 1e30 / 1e6 * 99 / 100,
            max: 1 * 1e30 / 1e6 * 101 / 100
        });

        (int256 price, /* MarketPoolValueInfo.Props memory info */) = reader.getMarketTokenPrice({
            dataStore: DATA_STORE,
            market: Market.Props({
                marketToken: GM_TOKEN_BTC_WBTC_USDC,
                indexToken: GMX_BTC_WBTC_USDC_INDEX,
                longToken: WBTC,
                shortToken: USDC
            }),
            indexTokenPrice: indexTokenPrice,
            longTokenPrice: longTokenPrice,
            shortTokenPrice: shortTokenPrice,
            pnlFactorType: Keys.MAX_PNL_FACTOR_FOR_DEPOSITS,
            maximize: true
        });

        return uint256(price);
    }

    // Task 3 - Create an order to deposit USDC into GM_TOKEN_BTC_WBTC_USDC
    function createDeposit(uint256 usdcAmount)
        external
        payable
        returns (bytes32 key)
    {
        uint256 executionFee = 0.1 * 1e18;
        usdc.transferFrom(msg.sender, address(this), usdcAmount);

        // Task 3.1 - Send execution fee to the deposit vault

        exchangeRouter.sendWnt{value: executionFee}({
            receiver: DEPOSIT_VAULT,
            amount: executionFee
        });

        // Task 3.2 - Send USDC to the deposit vault

        usdc.approve(ROUTER, usdcAmount);
        exchangeRouter.sendTokens({
            token: USDC,
            receiver: DEPOSIT_VAULT,
            amount: usdcAmount
        });

        // Task 3.3 - Create an order to deposit USDC into GM_TOKEN_BTC_WBTC_USDC
        // Assume 1 USDC = 1 USD
        // USDC has 6 decimals
        // Market token has 18 decimals

        uint256 marketTokenPrice = getMarketTokenPriceUsd(); // 30 decimals

        // Calculate min market tokens with slippage tolerance
        // Step 1: Convert USDC (6 decimals) to USD value (30 decimals)
        uint256 usdValue = (usdcAmount * 1e30) / 1e6;
        
        // Step 2: Calculate market tokens (18 decimals) = USD value / price
        // (30 decimals * 18 decimals) / 30 decimals = 18 decimals
        uint256 expectedMarketTokens = (usdValue * 1e18) / marketTokenPrice;
        
        // Step 3: Apply 1% slippage tolerance (99%)
        uint256 minMarketTokens = (expectedMarketTokens * 99) / 100;

        DepositUtils.CreateDepositParams memory createDepositParams = DepositUtils.CreateDepositParams({
            receiver: address(this),
            callbackContract: address(0),
            uiFeeReceiver: address(0),
            market: GM_TOKEN_BTC_WBTC_USDC,
            initialLongToken: WBTC,
            initialShortToken: USDC,
            longTokenSwapPath: new address[](0),
            shortTokenSwapPath: new address[](0),
            minMarketTokens: minMarketTokens,
            shouldUnwrapNativeToken: false,
            executionFee: executionFee,
            callbackGasLimit: 0
        });

        return exchangeRouter.createDeposit(createDepositParams);
    }

    // Task 4 - Create an order to withdraw liquidity from GM_TOKEN_BTC_WBTC_USDC
    function createWithdrawal() external payable returns (bytes32 key) {
        uint256 executionFee = 0.1 * 1e18;

        // Task 4.1 - Send execution fee to the withdrawal vault

        exchangeRouter.sendWnt{value: executionFee}({
            receiver: WITHDRAWAL_VAULT,
            amount: executionFee
        });

        // Task 4.2 - Send GM_TOKEN_BTC_WBTC_USDC to the withdrawal vault
        uint256 gmTokenAmount = gmToken.balanceOf(address(this));
        gmToken.approve(ROUTER, gmTokenAmount);
        exchangeRouter.sendTokens({
            token: GM_TOKEN_BTC_WBTC_USDC,
            receiver: WITHDRAWAL_VAULT,
            amount: gmTokenAmount
        });

        // Task 4.3 - Create an order to withdraw WBTC and USDC from GM_TOKEN_BTC_WBTC_USDC
        // Assume 1 USD = 1 USDC

        uint256 marketTokenPrice = getMarketTokenPriceUsd();
        uint256 marketTokenValue = marketTokenPrice * gmTokenAmount;
        uint256 btcPrice = oracle.getPrice(CHAINLINK_BTC_USD);
        // 1e30 * 1e18 / (1e8 * 1e32) = 1e8 = 1 WBTC
        uint256 minLongTokenAmount =
            marketTokenValue / 2 * 90 / 100 / (btcPrice * 1e32);
        // 1e30 * 1e18 / 1e42 = 1e6 = 1 USDC
        uint256 minShortTokenAmount = marketTokenValue / 2 * 90 / 100 / 1e42;

        WithdrawalUtils.CreateWithdrawalParams memory createWithdrawalParams = WithdrawalUtils.CreateWithdrawalParams({
            receiver: address(this),
            callbackContract: address(0),
            uiFeeReceiver: address(0),
            market: GM_TOKEN_BTC_WBTC_USDC,
            longTokenSwapPath: new address[](0),
            shortTokenSwapPath: new address[](0),
            minLongTokenAmount: minLongTokenAmount,
            minShortTokenAmount: minShortTokenAmount,
            shouldUnwrapNativeToken: false,
            executionFee: executionFee,
            callbackGasLimit: 0
        });

        return exchangeRouter.createWithdrawal(createWithdrawalParams);
    }
}
