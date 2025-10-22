// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console} from "forge-std/Test.sol";
import {IERC20} from "../../interfaces/IERC20.sol";
import {IExchangeRouter} from "../../interfaces/IExchangeRouter.sol";
import {IDataStore} from "../../interfaces/IDataStore.sol";
import {IReader} from "../../interfaces/IReader.sol";
import {Keys} from "../../lib/Keys.sol";
import {Math} from "../../lib/Math.sol";
import {Order} from "../../types/Order.sol";
import {Position} from "../../types/Position.sol";
import {MarketUtils} from "../../types/MarketUtils.sol";
import {Price} from "../../types/Price.sol";
import {ReaderPositionUtils} from "../../types/ReaderPositionUtils.sol";
import {IBaseOrderUtils} from "../../types/IBaseOrderUtils.sol";
import {Oracle} from "../../lib/Oracle.sol";
import "../../Constants.sol";

abstract contract GmxHelper {
    IDataStore constant dataStore = IDataStore(DATA_STORE);
    IExchangeRouter constant exchangeRouter = IExchangeRouter(EXCHANGE_ROUTER);
    IReader constant reader = IReader(READER);
    // Note: both long and short token price must return 8 decimals (1e8 = 1 USD)
    uint256 private constant CHAINLINK_MULTIPLIER = 1e8;
    uint256 private constant CHAINLINK_DECIMALS = 8;

    IERC20 public immutable marketToken;
    IERC20 public immutable longToken;
    IERC20 public immutable shortToken;
    uint256 public immutable longTokenDecimals;
    uint256 public immutable shortTokenDecimals;
    address public immutable chainlinkLongToken;
    address public immutable chainlinkShortToken;
    Oracle immutable oracle;

    constructor(
        address _marketToken,
        address _longToken,
        address _shortToken,
        address _chainlinkLongToken,
        address _chainlinkShortToken,
        address _oracle
    ) {
        marketToken = IERC20(_marketToken);
        longToken = IERC20(_longToken);
        shortToken = IERC20(_shortToken);

        longTokenDecimals = uint256(longToken.decimals());
        shortTokenDecimals = uint256(shortToken.decimals());
        require(
            longTokenDecimals + CHAINLINK_DECIMALS <= 30,
            "long + chainlink decimals > 30"
        );
        require(
            shortTokenDecimals + CHAINLINK_DECIMALS <= 30,
            "short + chainlink decimals > 30"
        );

        chainlinkLongToken = _chainlinkLongToken;
        chainlinkShortToken = _chainlinkShortToken;
        oracle = Oracle(_oracle);
    }

    function getPositionKey() internal view returns (bytes32 positionKey) {
        return Position.getPositionKey({
            account: address(this),
            market: address(marketToken),
            collateralToken: address(longToken),
            isLong: false
        });
    }

    function getPosition(bytes32 positionKey)
        internal
        view
        returns (Position.Props memory)
    {
        return reader.getPosition(address(dataStore), positionKey);
    }

    // Returns collateral amount locked in the current position
    function getPositionCollateralAmount() internal view returns (uint256) {
        bytes32 positionKey = getPositionKey();
        Position.Props memory position = getPosition(positionKey);
        return position.numbers.collateralAmount;
    }

    // Returns the max callback gas limit used for calling a callback contract
    // once a order is executed.
    function getMaxCallbackGasLimit() internal view returns (uint256) {
        return dataStore.getUint(Keys.MAX_CALLBACK_GAS_LIMIT);
    }

    // Returns position collateral amount + profit and loss of the position in terms of the collateral token
    function getPositionWithPnlInToken() internal view returns (int256) {
        bytes32 positionKey = getPositionKey();
        Position.Props memory position = getPosition(positionKey);

        if (
            position.numbers.sizeInUsd == 0
                || position.numbers.collateralAmount == 0
        ) {
            return 0;
        }

        uint256 longTokenPrice = oracle.getPrice(chainlinkLongToken);
        uint256 shortTokenPrice = oracle.getPrice(chainlinkShortToken);

        // +/- 0.1% of current prices of the long token
        uint256 minLongTokenPrice = longTokenPrice
            * 10 ** (30 - CHAINLINK_DECIMALS - longTokenDecimals) * 999 / 1000;
        uint256 maxLongTokenPrice = longTokenPrice
            * 10 ** (30 - CHAINLINK_DECIMALS - longTokenDecimals) * 1001 / 1000;

        require(minLongTokenPrice > 0, "min long token price = 0");
        require(maxLongTokenPrice > 0, "max long token price = 0");

        MarketUtils.MarketPrices memory prices = MarketUtils.MarketPrices({
            indexTokenPrice: Price.Props({
                min: minLongTokenPrice,
                max: maxLongTokenPrice
            }),
            longTokenPrice: Price.Props({
                min: minLongTokenPrice,
                max: maxLongTokenPrice
            }),
            shortTokenPrice: Price.Props({
                min: shortTokenPrice
                    * 10 ** (30 - CHAINLINK_DECIMALS - shortTokenDecimals) * 999 / 1000,
                max: shortTokenPrice
                    * 10 ** (30 - CHAINLINK_DECIMALS - shortTokenDecimals) * 1001 / 1000
            })
        });

        ReaderPositionUtils.PositionInfo memory info = reader.getPositionInfo({
            dataStore: address(dataStore),
            referralStorage: REFERRAL_STORAGE,
            positionKey: positionKey,
            prices: prices,
            // Use current position size for size delta
            sizeDeltaUsd: 0,
            uiFeeReceiver: address(0),
            usePositionSizeAsSizeDeltaUsd: true
        });

        int256 collateralUsd =
            Math.toInt256(position.numbers.collateralAmount * minLongTokenPrice);
        int256 collateralCostUsd =
            Math.toInt256(info.fees.totalCostAmount * minLongTokenPrice);

        int256 remainingCollateralUsd =
            collateralUsd + info.pnlAfterPriceImpactUsd - collateralCostUsd;

        int256 remainingCollateral =
            remainingCollateralUsd / Math.toInt256(minLongTokenPrice);

        return remainingCollateral;
    }

    // Task 1: Calculate position size delta
    function getSizeDeltaUsd(
        // Long token price from Chainlink (1e8 = 1 USD)
        uint256 longTokenPrice,
        // Current position size
        uint256 sizeInUsd,
        // Current collateral amount locked in the position
        uint256 collateralAmount,
        // Long token amount to add or remove
        uint256 longTokenAmount,
        // True for market increase
        bool isIncrease
    ) internal view returns (uint256 sizeDeltaUsd) {
        // Calculate sizeDeltaUsd so that new position's leverage is close to 1
        if (isIncrease) {
            // new position size = long token price * new collateral amount
            // new collateral amount = position.collateralAmount + longTokenAmount
            // sizeDeltaUsd = new position size - position.sizeInUsd

            uint256 newCollateralAmount = collateralAmount + longTokenAmount;
            uint256 newPositionSizeInUsd = newCollateralAmount * longTokenPrice * 10 ** (30 - longTokenDecimals - CHAINLINK_DECIMALS);
            // Returns 0 if new position size is smaller than current size
            if (newPositionSizeInUsd > sizeInUsd) sizeDeltaUsd = newPositionSizeInUsd - sizeInUsd;

        } else {
            // new position size = long token price * new collateral amount
            // new collateral amount = position.collateralAmount - longTokenAmount
            // sizeDeltaUsd = new position size - position.sizeInUsd

            uint256 newCollateralAmount = collateralAmount - longTokenAmount;
            uint256 newPositionSizeInUsd = newCollateralAmount * longTokenPrice * 10 ** (30 - longTokenDecimals - CHAINLINK_DECIMALS);
            // Returns 0 if new position size is smaller than current size
            if (sizeInUsd > newPositionSizeInUsd) sizeDeltaUsd = sizeInUsd - newPositionSizeInUsd;
        }
    }

    // Task 2: Create market increase order
    function createIncreaseShortPositionOrder(
        // Execution fee to send to the order vault
        uint256 executionFee,
        // Long token amount to add to the current position
        uint256 longTokenAmount
    ) internal returns (bytes32 orderKey) {
        uint256 longTokenPrice = oracle.getPrice(chainlinkLongToken);
        bytes32 positionKey = getPositionKey();
        Position.Props memory position = getPosition(positionKey);

        // Task 2.1 - Calculate position size delta

        uint256 sizeDeltaUsd = getSizeDeltaUsd({
            longTokenPrice: longTokenPrice,
            sizeInUsd: position.numbers.sizeInUsd,
            collateralAmount: position.numbers.collateralAmount,
            longTokenAmount: longTokenAmount,
            isIncrease: true
        });

        // Task 2.2 - Create market increase order

        exchangeRouter.sendWnt{value: executionFee}({
            receiver: ORDER_VAULT,
            amount: executionFee
        });

        longToken.approve(ROUTER, longTokenAmount);
        exchangeRouter.sendTokens({
            token: address(longToken),
            receiver: ORDER_VAULT,
            amount: longTokenAmount
        });

        uint256 acceptablePrice = longTokenPrice * 1e12 / CHAINLINK_MULTIPLIER * 90 / 100; // acceptablePrice requires 12 decimals -> with 10% slippage

        return exchangeRouter.createOrder(
            IBaseOrderUtils.CreateOrderParams({
                addresses: IBaseOrderUtils.CreateOrderParamsAddresses({
                    receiver: address(this),
                    cancellationReceiver: address(0),
                    callbackContract: address(0),
                    uiFeeReceiver: address(0),
                    market: address(marketToken),
                    initialCollateralToken: address(longToken),
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
                isLong: false,
                shouldUnwrapNativeToken: false,
                autoCancel: false,
                referralCode: bytes32(uint256(0))
            })
        );
    }

    // Task 3: Create market decrease order
    function createDecreaseShortPositionOrder(
        // Execution fee to send to the order vault
        uint256 executionFee,
        // Long token amount to remove from the current position
        uint256 longTokenAmount,
        // Receiver of long token
        address receiver,
        // Callback contract used to handle withdrawal from the vault
        address callbackContract,
        // Max gas to send to the callback contract
        uint256 callbackGasLimit
    ) internal returns (bytes32 orderKey) {
        uint256 longTokenPrice = oracle.getPrice(chainlinkLongToken);
        bytes32 positionKey = getPositionKey();
        Position.Props memory position = getPosition(positionKey);

        require(position.numbers.sizeInUsd > 0, "position size = 0");

        longTokenAmount =
            Math.min(longTokenAmount, position.numbers.collateralAmount);
        require(longTokenAmount > 0, "long token amount = 0");

        // Task 3.1 - Calculate position size delta

        uint256 sizeDeltaUsd = getSizeDeltaUsd({
            longTokenPrice: longTokenPrice,
            sizeInUsd: position.numbers.sizeInUsd,
            collateralAmount: position.numbers.collateralAmount,
            longTokenAmount: longTokenAmount,
            isIncrease: false
        });

        // Task 3.2 - Send market decrease order

        exchangeRouter.sendWnt{value: executionFee}({
            receiver: ORDER_VAULT,
            amount: executionFee
        });

        uint256 acceptablePrice = longTokenPrice * 1e12 / CHAINLINK_MULTIPLIER * 110 / 100; // acceptablePrice requires 12 decimals -> with 10% slippage

        return exchangeRouter.createOrder(
            IBaseOrderUtils.CreateOrderParams({
                addresses: IBaseOrderUtils.CreateOrderParamsAddresses({
                    receiver: receiver,
                    cancellationReceiver: address(0),
                    callbackContract: callbackContract,
                    uiFeeReceiver: address(0),
                    market: address(marketToken),
                    initialCollateralToken: address(longToken),
                    swapPath: new address[](0)
                }),
                numbers: IBaseOrderUtils.CreateOrderParamsNumbers({
                    sizeDeltaUsd: sizeDeltaUsd,
                    initialCollateralDeltaAmount: longTokenAmount,
                    triggerPrice: 0,
                    acceptablePrice: acceptablePrice,
                    executionFee: executionFee,
                    callbackGasLimit: callbackGasLimit,
                    minOutputAmount: 0,
                    validFromTime: 0
                }),
                orderType: Order.OrderType.MarketDecrease,
                decreasePositionSwapType: Order.DecreasePositionSwapType.SwapPnlTokenToCollateralToken,
                isLong: false,
                shouldUnwrapNativeToken: false,
                autoCancel: false,
                referralCode: bytes32(uint256(0))
            })
        );

        // Decreasing position that results in small position size causes liquidation error
    }

    // Task 4: Cancel order
    function cancelOrder(bytes32 orderKey) internal {
        exchangeRouter.cancelOrder(orderKey);
    }

    // Task 5: Claim funding fees
    function claimFundingFees() internal {
        address[] memory markets = new address[](1);
        markets[0] = address(marketToken);

        address[] memory tokens = new address[](1);
        tokens[0] = address(longToken);
        
        exchangeRouter.claimFundingFees({
            markets: markets,
            tokens: tokens,
            receiver: address(this)
        });
    }
}
