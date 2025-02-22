// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../src/price-feeds/PriceOracle.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";


contract MockAggregator is AggregatorV3Interface {
    int256 private _price;
    uint256 private _updatedAt;
    uint80 private _roundId;
    uint80 private _answeredInRound;

    function setPrice(int256 price) external {
        _price = price;
        _updatedAt = block.timestamp;
        _roundId++;
        _answeredInRound = _roundId;
    }

    function setPriceWithTimestamp(int256 price, uint256 timestamp) external {
        _price = price;
        _updatedAt = timestamp;
        _roundId++;
        _answeredInRound = _roundId;
    }

    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    ) {
        return (_roundId, _price, _updatedAt, _updatedAt, _answeredInRound);
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function description() external pure returns (string memory) {
        return "Mock ETH/USD";
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function getRoundData(uint80) external pure returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    ) {
        return (0, 0, 0, 0, 0);
    }
}

contract PriceOracleTest is Test {
    PriceOracle public oracle;
    MockAggregator public mockAggregator;

    address constant SCROLL_SEPOLIA_ETH_USD = 0x59F1ec1f10bD7eD9B938431086bC1D9e233ECf41;
    uint256 constant INITIAL_PRICE = 2000e8; // $2000 USD/ETH

    event FallbackPriceUpdated(uint256 price);
    event StalePrice(uint256 timestamp, uint256 lastUpdateTime);

    function setUp() public {
        // Start with a known timestamp
        vm.warp(1000);
        
        // Deploy mock for local testing
        mockAggregator = new MockAggregator();
        mockAggregator.setPrice(int256(INITIAL_PRICE));
        oracle = new PriceOracle(address(mockAggregator));
    }

    function testInitialization() public view {
        assertEq(address(oracle.ethUsdPriceFeed()), address(mockAggregator));
    }

    function testGetLatestPrice() public {
        mockAggregator.setPrice(int256(INITIAL_PRICE));
        uint256 price = oracle.getLatestPrice();
        assertEq(price, INITIAL_PRICE);
    }

    function testEthToUsdc() public {
        mockAggregator.setPrice(int256(INITIAL_PRICE));
        uint256 ethAmount = 1 ether;
        uint256 expectedUsdc = 2000e6;
        uint256 convertedAmount = oracle.ethToUsdc(ethAmount);
        assertEq(convertedAmount, expectedUsdc);
    }

    function testUsdcToEth() public {
        mockAggregator.setPrice(int256(INITIAL_PRICE));
        uint256 usdcAmount = 2000e6;
        uint256 expectedEth = 1 ether;
        uint256 convertedAmount = oracle.usdcToEth(usdcAmount);
        assertEq(convertedAmount, expectedEth);
    }

    function testFallbackPrice() public {
        uint256 baseTimestamp = block.timestamp;
        uint256 newFallbackPrice = 1900e8;
        
        // Set initial price and update fallback
        mockAggregator.setPrice(int256(INITIAL_PRICE));
        oracle.updateFallbackPrice(newFallbackPrice);
        
        // Move time forward but stay within grace period
        uint256 staleTime = baseTimestamp + oracle.HEARTBEAT_PERIOD() + 1;
        vm.warp(staleTime);
        
        // Set a stale price
        mockAggregator.setPriceWithTimestamp(int256(INITIAL_PRICE), baseTimestamp);
        
        // Should use fallback price
        uint256 price = oracle.getLatestPrice();
        assertEq(price, newFallbackPrice);
    }

    function testRevertOnStalePriceAfterGracePeriod() public {
        vm.warp(block.timestamp + oracle.HEARTBEAT_PERIOD() + oracle.GRACE_PERIOD() + 1);
        vm.expectRevert(PriceOracle.StalePriceData.selector);
        oracle.getLatestPrice();
    }

    function testRevertOnInvalidPrice() public {
        mockAggregator.setPrice(-1);
        vm.expectRevert(PriceOracle.InvalidPrice.selector);
        oracle.getLatestPrice();
    }

    function testPriceFeedHealth() public {
        mockAggregator.setPrice(int256(INITIAL_PRICE));
        assertTrue(oracle.isPriceFeedHealthy());

        vm.warp(block.timestamp + oracle.HEARTBEAT_PERIOD() + 1);
        assertFalse(oracle.isPriceFeedHealthy());
    }

    function testFuzzingEthToUsdc(uint256 ethAmount) public {
        // Ensure amount is reasonable and not too small
        vm.assume(ethAmount >= 1e15 && ethAmount < 1000000 ether);
        
        mockAggregator.setPrice(int256(INITIAL_PRICE));
        
        uint256 usdcAmount = oracle.ethToUsdc(ethAmount);
        uint256 backToEth = oracle.usdcToEth(usdcAmount);
        
        // Allow for larger rounding errors with smaller amounts
        uint256 tolerance = ethAmount < 1 ether ? 1e17 : 5e16; // 10% for small amounts, 5% for larger
        assertApproxEqRel(backToEth, ethAmount, tolerance);
    }
}

