// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import "../lib/TestHelper.sol";
import {DecreaseCallback} from "./DecreaseCallback.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";
import {IReader} from "../../src/interfaces/IReader.sol";
import {IOrderHandler} from "../../src/interfaces/IOrderHandler.sol";
import {OracleUtils} from "../../src/types/OracleUtils.sol";
import {Order} from "../../src/types/Order.sol";
import {Position} from "../../src/types/Position.sol";
import "../../src/Constants.sol";
import {Math} from "../../src/lib/Math.sol";
import {Role} from "../../src/lib/Role.sol";
import {Oracle} from "../../src/lib/Oracle.sol";
import {Vault} from "@exercises/app/Vault.sol";
import {WithdrawCallback} from "@exercises/app/WithdrawCallback.sol";
import {Strategy} from "@exercises/app/Strategy.sol";
import {IRoleStore} from "../../src/interfaces/IRoleStore.sol";

contract StrategyTestHelper is Test {
    IERC20 internal constant weth = IERC20(WETH);
    IERC20 internal constant usdc = IERC20(USDC);
    IReader internal constant reader = IReader(READER);
    IOrderHandler internal constant orderHandler = IOrderHandler(ORDER_HANDLER);
    uint256 internal constant EXECUTION_FEE = 0.01 * 1e18;

    TestHelper internal testHelper;
    Oracle internal oracle;
    Vault internal vault;
    Strategy internal strategy;
    WithdrawCallback internal withdrawCallback;
    address internal keeper;

    // Oracle params
    address[] internal tokens;
    address[] internal providers;
    bytes[] internal data;
    TestHelper.OracleParams[] internal oracles;
    bytes32 internal positionKey;

    bool internal debug = true;

    receive() external payable {}

    function setUp() public virtual {
        testHelper = new TestHelper();
        keeper = testHelper.getRoleMember(Role.ORDER_KEEPER);
        oracle = new Oracle();
        vault = new Vault();
        strategy = new Strategy(address(oracle));
        withdrawCallback = new WithdrawCallback(address(vault));

        vault.setStrategy(address(strategy));
        vault.setWithdrawCallback(address(withdrawCallback));

        // Approve vault to pull WETH from strategy
        strategy.allow(address(vault));
        // Allow callback to call vault
        vault.allow(address(withdrawCallback));

        // Grant necessary roles
        address admin = testHelper.getRoleMember(Role.ROLE_ADMIN);
        IRoleStore roleStore = IRoleStore(ROLE_STORE);
        
        vm.startPrank(admin);
        roleStore.grantRole(EXCHANGE_ROUTER, Role.ROUTER_PLUGIN);
        roleStore.grantRole(EXCHANGE_ROUTER, Role.CONTROLLER);
        roleStore.grantRole(ORDER_HANDLER, Role.CONTROLLER);
        vm.stopPrank();

        deal(WETH, address(this), 1000 * 1e18);

        tokens = new address[](2);
        tokens[0] = USDC;
        tokens[1] = WETH;

        providers = new address[](2);
        providers[0] = CHAINLINK_DATA_STREAM_PROVIDER;
        providers[1] = CHAINLINK_DATA_STREAM_PROVIDER;

        // NOTE: data kept empty for mock calls
        data = new bytes[](2);

        oracles = new TestHelper.OracleParams[](2);
        oracles[0] = TestHelper.OracleParams({
            chainlink: CHAINLINK_USDC_USD,
            multiplier: 1,
            deltaPrice: 0
        });
        oracles[1] = TestHelper.OracleParams({
            chainlink: CHAINLINK_ETH_USD,
            multiplier: 1,
            deltaPrice: 0
        });

        positionKey = Position.getPositionKey({
            account: address(strategy),
            market: GM_TOKEN_ETH_WETH_USDC,
            collateralToken: WETH,
            isLong: false
        });
    }

    function inc(uint256 wethAmount) public returns (bytes32 orderKey) {
        uint256 ethPrice = oracle.getPrice(CHAINLINK_ETH_USD);

        orderKey = strategy.increase{value: EXECUTION_FEE}(wethAmount);

        Order.Props memory order = reader.getOrder(DATA_STORE, orderKey);

        assertEq(
            order.addresses.receiver, address(strategy), "inc: order receiver"
        );
        assertEq(order.addresses.market, GM_TOKEN_ETH_WETH_USDC, "inc: market");
        assertEq(
            order.addresses.initialCollateralToken,
            WETH,
            "inc: initial collateral token"
        );
        assertEq(
            uint256(order.numbers.orderType),
            uint256(Order.OrderType.MarketIncrease),
            "inc: order type"
        );
        assertEq(
            order.numbers.initialCollateralDeltaAmount,
            wethAmount,
            "inc: initial collateral delta amount"
        );
        assertApproxEqRel(
            order.numbers.sizeDeltaUsd,
            ethPrice * wethAmount * 1e30 / 1e26,
            1e18 / 100,
            "inc: size delta USD"
        );
        assertEq(order.flags.isLong, false, "inc: not short");

        // Execute order
        skip(1);

        Position.Props memory p0 = reader.getPosition(DATA_STORE, positionKey);

        testHelper.mockOraclePrices({
            tokens: tokens,
            providers: providers,
            data: data,
            oracles: oracles
        });

        vm.prank(keeper);
        orderHandler.executeOrder(
            orderKey,
            OracleUtils.SetPricesParams({
                tokens: tokens,
                providers: providers,
                data: data
            })
        );

        Position.Props memory p1 = reader.getPosition(DATA_STORE, positionKey);

        assertApproxEqRel(
            p1.numbers.sizeInUsd,
            p0.numbers.sizeInUsd + ethPrice * wethAmount * 1e4,
            1e18 * 2 / 100,
            "inc: position size"
        );
        assertGe(
            p1.numbers.collateralAmount,
            p0.numbers.collateralAmount + wethAmount * 99 / 100,
            "inc: position collateral amount"
        );
        assertEq(
            p1.addresses.account, address(strategy), "inc: position account"
        );
        assertApproxEqRel(
            p1.numbers.sizeInUsd,
            p1.numbers.collateralAmount * ethPrice * 1e4,
            1e18 / 100,
            "inc: size in USD != collateral * price"
        );

        if (debug) {
            console.log("--------------");
            console.log("inc: position size %e", p1.numbers.sizeInUsd);
            console.log(
                "inc: position size in tokens %e", p1.numbers.sizeInTokens
            );
            console.log(
                "inc: position collateral %e", p1.numbers.collateralAmount
            );
            console.log("inc: total value: %e", strategy.totalValueInToken());
            console.log(
                "inc: WETH balance %e", weth.balanceOf(address(strategy))
            );
        }
    }

    function dec(uint256 wethAmount, address callback)
        public
        returns (bytes32 orderKey)
    {
        uint256 ethPrice = oracle.getPrice(CHAINLINK_ETH_USD);

        orderKey = strategy.decrease{value: EXECUTION_FEE}(wethAmount, callback);

        Position.Props memory p0 = reader.getPosition(DATA_STORE, positionKey);
        Order.Props memory order = reader.getOrder(DATA_STORE, orderKey);

        address receiver = callback == address(0) ? address(strategy) : callback;
        assertEq(order.addresses.receiver, receiver, "dec: order receiver");

        assertEq(order.addresses.market, GM_TOKEN_ETH_WETH_USDC, "dec: market");
        assertEq(
            order.addresses.initialCollateralToken,
            WETH,
            "dec: initial collateral token"
        );
        assertEq(
            uint256(order.numbers.orderType),
            uint256(Order.OrderType.MarketDecrease),
            "dec: order type"
        );
        if (callback == address(0)) {
            assertEq(
                order.numbers.initialCollateralDeltaAmount,
                Math.min(wethAmount, p0.numbers.collateralAmount),
                "dec: initial collateral delta amount"
            );
        } else {
            assertApproxEqRel(
                order.numbers.initialCollateralDeltaAmount,
                Math.min(wethAmount, p0.numbers.collateralAmount),
                1e18 * 1 / 100,
                "dec: initial collateral delta amount"
            );
        }
        assertApproxEqRel(
            order.numbers.sizeDeltaUsd,
            ethPrice * wethAmount * 1e30 / 1e26,
            1e18 * 10 / 100,
            "dec: size delta USD"
        );
        assertEq(order.flags.isLong, false, "dec: not short");

        // Execute dec order
        skip(1);

        testHelper.set("WETH before", weth.balanceOf(receiver));
        testHelper.set("USDC before", weth.balanceOf(receiver));

        testHelper.mockOraclePrices({
            tokens: tokens,
            providers: providers,
            data: data,
            oracles: oracles
        });

        vm.prank(keeper);
        orderHandler.executeOrder(
            orderKey,
            OracleUtils.SetPricesParams({
                tokens: tokens,
                providers: providers,
                data: data
            })
        );

        testHelper.set("WETH after", weth.balanceOf(receiver));
        testHelper.set("USDC after", weth.balanceOf(receiver));

        uint256 wethDiff =
            testHelper.get("WETH after") - testHelper.get("WETH before");
        uint256 usdcDiff =
            testHelper.get("USDC after") - testHelper.get("USDC after");

        assertGe(wethDiff, wethAmount * 80 / 100, "WETH difference");
        assertEq(usdcDiff, 0, "USDC difference != 0");

        Position.Props memory p1 = reader.getPosition(DATA_STORE, positionKey);

        assertEq(
            p1.numbers.sizeInUsd,
            p0.numbers.sizeInUsd - order.numbers.sizeDeltaUsd,
            "dec: position size"
        );
        if (wethAmount >= p0.numbers.collateralAmount) {
            assertEq(
                p1.numbers.collateralAmount,
                0,
                "dec: position collateral amount != 0"
            );
        } else {
            assertApproxEqRel(
                p1.numbers.collateralAmount,
                p0.numbers.collateralAmount - wethAmount,
                1e18 * 10 / 100,
                "dec: position collateral amount"
            );
        }

        if (p1.numbers.sizeInUsd > 0) {
            assertApproxEqRel(
                p1.numbers.sizeInUsd,
                p1.numbers.collateralAmount * ethPrice * 1e4,
                1e18 * 10 / 100,
                "dec: size in USD != collateral * price"
            );
        }

        if (debug) {
            console.log("--------------");
            console.log("dec: position size %e", p1.numbers.sizeInUsd);
            console.log(
                "dec: position size in tokens %e", p1.numbers.sizeInTokens
            );
            console.log(
                "dec: position collateral %e", p1.numbers.collateralAmount
            );
            console.log("dec: total value: %e", strategy.totalValueInToken());
            console.log("dec: WETH balance %e", weth.balanceOf(receiver));
            console.log("dec: WETH diff %e", wethDiff);
        }
    }
}
