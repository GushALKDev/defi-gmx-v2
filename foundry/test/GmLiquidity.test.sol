// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import "./lib/TestHelper.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IDepositHandler} from "../src/interfaces/IDepositHandler.sol";
import {IWithdrawalHandler} from "../src/interfaces/IWithdrawalHandler.sol";
import {IReader} from "../src/interfaces/IReader.sol";
import {IRoleStore} from "../src/interfaces/IRoleStore.sol";
import {OracleUtils} from "../src/types/OracleUtils.sol";
import {Deposit} from "../src/types/Deposit.sol";
import {Withdrawal} from "../src/types/Withdrawal.sol";
import "../src/Constants.sol";
import {Role} from "../src/lib/Role.sol";
import {Oracle} from "../src/lib/Oracle.sol";
import {GmLiquidity} from "@exercises/GmLiquidity.sol";

contract GmLiquidityTest is Test {
    IERC20 constant wbtc = IERC20(WBTC);
    IERC20 constant usdc = IERC20(USDC);
    IERC20 constant gmToken = IERC20(GM_TOKEN_BTC_WBTC_USDC);
    IDepositHandler constant depositHandler = IDepositHandler(DEPOSIT_HANDLER);
    IWithdrawalHandler constant withdrawalHandler =
        IWithdrawalHandler(WITHDRAWAL_HANDLER);
    IReader constant reader = IReader(READER);

    TestHelper testHelper;
    Oracle oracle;
    GmLiquidity gmLiquidity;
    address keeper;

    // Oracle params
    address[] tokens;
    address[] providers;
    bytes[] data;
    TestHelper.OracleParams[] oracles;

    function setUp() public {
        testHelper = new TestHelper();
        keeper = testHelper.getRoleMember(Role.ORDER_KEEPER);
        oracle = new Oracle();

        gmLiquidity = new GmLiquidity(address(oracle));
        
        // Grant CONTROLLER and ROUTER_PLUGIN roles to gmLiquidity and routers
        address roleAdmin = testHelper.getRoleMember(Role.ROLE_ADMIN);
        vm.startPrank(roleAdmin);
        IRoleStore(ROLE_STORE).grantRole(address(gmLiquidity), Role.CONTROLLER);
        IRoleStore(ROLE_STORE).grantRole(EXCHANGE_ROUTER, Role.CONTROLLER);
        IRoleStore(ROLE_STORE).grantRole(EXCHANGE_ROUTER, Role.ROUTER_PLUGIN);
        IRoleStore(ROLE_STORE).grantRole(DEPOSIT_HANDLER, Role.CONTROLLER);
        IRoleStore(ROLE_STORE).grantRole(WITHDRAWAL_HANDLER, Role.CONTROLLER);
        vm.stopPrank();
        
        deal(USDC, address(this), 1000 * 1e6);

        tokens = new address[](3);
        tokens[0] = GMX_BTC_WBTC_USDC_INDEX;
        tokens[1] = USDC;
        tokens[2] = WBTC;

        providers = new address[](3);
        providers[0] = CHAINLINK_DATA_STREAM_PROVIDER;
        providers[1] = CHAINLINK_DATA_STREAM_PROVIDER;
        providers[2] = CHAINLINK_DATA_STREAM_PROVIDER;

        // NOTE: data kept empty for mock calls
        data = new bytes[](3);

        oracles = new TestHelper.OracleParams[](3);
        oracles[0] = TestHelper.OracleParams({
            chainlink: CHAINLINK_BTC_USD,
            // Same as WBTC decimals
            multiplier: 1e8,
            deltaPrice: 0
        });
        oracles[1] = TestHelper.OracleParams({
            chainlink: CHAINLINK_USDC_USD,
            multiplier: 1,
            deltaPrice: 0
        });
        oracles[2] = TestHelper.OracleParams({
            chainlink: CHAINLINK_WBTC_USD,
            multiplier: 1,
            deltaPrice: 0
        });
    }

    function testMarketLiquidity() public {
        uint256 executionFee = 0.1 * 1e18;
        uint256 usdcAmount = 1000 * 1e6;
        usdc.approve(address(gmLiquidity), usdcAmount);

        // Test market token price
        uint256 marketTokenPrice = gmLiquidity.getMarketTokenPriceUsd();
        assertGt(marketTokenPrice, 0, "market token price = 0");

        uint256 minMarketTokenAmount =
            usdcAmount * 1e24 * 1e18 / marketTokenPrice;
        console.log("Min market token amount %e", minMarketTokenAmount);

        // Create deposit order
        bytes32 depositKey =
            gmLiquidity.createDeposit{value: executionFee}(usdcAmount);

        Deposit.Props memory deposit = reader.getDeposit(DATA_STORE, depositKey);
        assertEq(
            deposit.addresses.receiver, address(gmLiquidity), "deposit receiver"
        );
        assertEq(
            deposit.addresses.market, GM_TOKEN_BTC_WBTC_USDC, "deposit market"
        );
        assertGt(
            deposit.numbers.initialShortTokenAmount,
            0,
            "deposit initial short token amount"
        );

        // Execute deposit
        skip(1);

        testHelper.mockOraclePrices({
            tokens: tokens,
            providers: providers,
            data: data,
            oracles: oracles
        });

        testHelper.set(
            "GM token gmLiquidity before",
            gmToken.balanceOf(address(gmLiquidity))
        );

        vm.prank(keeper);
        depositHandler.executeDeposit(
            depositKey,
            OracleUtils.SetPricesParams({
                tokens: tokens,
                providers: providers,
                data: data
            })
        );

        testHelper.set(
            "GM token gmLiquidity after",
            gmToken.balanceOf(address(gmLiquidity))
        );

        console.log(
            "GM token gmLiquidity: %e",
            testHelper.get("GM token gmLiquidity after")
        );

        assertGt(
            testHelper.get("GM token gmLiquidity after"),
            testHelper.get("GM token gmLiquidity before"),
            "GM token gmLiquidity"
        );

        assertGe(
            testHelper.get("GM token gmLiquidity after"),
            minMarketTokenAmount,
            "Min GM token amount"
        );

        // Create withdrawal order
        skip(1);

        testHelper.set(
            "GM token gmLiquidity before",
            gmToken.balanceOf(address(gmLiquidity))
        );

        bytes32 withdrawalKey =
            gmLiquidity.createWithdrawal{value: executionFee}();

        testHelper.set(
            "GM token gmLiquidity after",
            gmToken.balanceOf(address(gmLiquidity))
        );

        Withdrawal.Props memory withdrawal =
            reader.getWithdrawal(DATA_STORE, withdrawalKey);
        assertEq(
            withdrawal.addresses.receiver,
            address(gmLiquidity),
            "withdrawal receiver"
        );
        assertEq(
            withdrawal.addresses.market,
            GM_TOKEN_BTC_WBTC_USDC,
            "withdrawal market"
        );
        assertGt(
            withdrawal.numbers.marketTokenAmount,
            0,
            "withdrawal market token amount"
        );

        assertEq(
            testHelper.get("GM token gmLiquidity after"),
            0,
            "GM token gmLiquidity"
        );

        // Execute withdrawal
        skip(1);

        testHelper.set(
            "WBTC gmLiquidity before", wbtc.balanceOf(address(gmLiquidity))
        );
        testHelper.set(
            "USDC gmLiquidity before", usdc.balanceOf(address(gmLiquidity))
        );
        testHelper.set(
            "GM token gmLiquidity before",
            gmToken.balanceOf(address(gmLiquidity))
        );

        testHelper.mockOraclePrices({
            tokens: tokens,
            providers: providers,
            data: data,
            oracles: oracles
        });

        vm.prank(keeper);
        withdrawalHandler.executeWithdrawal(
            withdrawalKey,
            OracleUtils.SetPricesParams({
                tokens: tokens,
                providers: providers,
                data: data
            })
        );

        testHelper.set(
            "WBTC gmLiquidity after", wbtc.balanceOf(address(gmLiquidity))
        );
        testHelper.set(
            "USDC gmLiquidity after", usdc.balanceOf(address(gmLiquidity))
        );
        testHelper.set(
            "GM token gmLiquidity after",
            gmToken.balanceOf(address(gmLiquidity))
        );

        console.log(
            "WBTC gmLiquidity: %e", testHelper.get("WBTC gmLiquidity after")
        );
        console.log(
            "USDC gmLiquidity: %e", testHelper.get("USDC gmLiquidity after")
        );

        assertGt(
            testHelper.get("WBTC gmLiquidity after"),
            testHelper.get("WBTC gmLiquidity before"),
            "WBTC gmLiquidity"
        );
        assertGt(
            testHelper.get("USDC gmLiquidity after"),
            testHelper.get("USDC gmLiquidity before"),
            "USDC gmLiquidity"
        );
        assertGe(
            testHelper.get("GM token gmLiquidity after"),
            0,
            "GM token gmLiquidity"
        );
    }
}
