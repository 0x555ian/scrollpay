// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title PriceOracle
 * @dev A smart contract to fetch ETH/USD price from Chainlink and provide ETH to USDC conversion.
 *      Supports a fallback price mechanism in case the primary feed fails.
 */
contract PriceOracle is Ownable {
    /// @notice Chainlink price feed for ETH/USD
    AggregatorV3Interface public immutable ethUsdPriceFeed;
    
    uint256 public constant PRICE_PRECISION = 8;  // Chainlink ETH/USD feed decimals
    uint256 public constant ETH_DECIMALS = 18;    // ETH decimals
    uint256 public constant USDC_DECIMALS = 6;    // USDC decimals
    uint256 public constant HEARTBEAT_PERIOD = 1 hours; // Validity period for price feed
    uint256 public constant GRACE_PERIOD = 1 hours; // Extra time allowed for fallback price
    
    uint256 public fallbackPrice; // Stored fallback price
    uint256 public lastFallbackUpdate; // Timestamp of last fallback price update
    
    /// @notice Emitted when the Chainlink price feed address is updated
    event PriceFeedUpdated(address indexed feed);
    /// @notice Emitted when the fallback price is updated
    event FallbackPriceUpdated(uint256 price);
    /// @notice Emitted when a stale price is detected
    event StalePrice(uint256 timestamp, uint256 lastUpdateTime);
    
    error InvalidPriceFeed();
    error StalePriceData();
    error InvalidPrice();
    error GracePeriodNotMet();

    /**
     * @notice Constructor to initialize the PriceOracle contract.
     * @param _ethUsdPriceFeed Address of the Chainlink ETH/USD price feed.
     */
    constructor(address _ethUsdPriceFeed) Ownable(msg.sender) {
        if (_ethUsdPriceFeed == address(0)) revert InvalidPriceFeed();
        ethUsdPriceFeed = AggregatorV3Interface(_ethUsdPriceFeed);
    }

    /**
     * @notice Fetches the latest ETH/USD price from the Chainlink price feed.
     * @dev Uses fallback price if Chainlink feed is stale or unavailable.
     * @return price The latest ETH/USD price with 8 decimal places.
     */
    function getLatestPrice() public view returns (uint256 price) {
        try ethUsdPriceFeed.latestRoundData() returns (
            uint80 roundId,
            int256 answer,
            uint256,  // startedAt not used
            uint256 updatedAt,
            uint80 answeredInRound
        ) {
            // Check for stale data
            if (block.timestamp > updatedAt + HEARTBEAT_PERIOD) {
                // Use fallback price if within grace period
                if (block.timestamp <= updatedAt + HEARTBEAT_PERIOD + GRACE_PERIOD &&
                    lastFallbackUpdate + HEARTBEAT_PERIOD >= updatedAt) {
                    return fallbackPrice;
                }
                revert StalePriceData();
            }

            // Validate the price feed data
            if (answer <= 0) revert InvalidPrice();
            if (updatedAt == 0) revert InvalidPrice();
            if (answeredInRound < roundId) revert StalePriceData();

            return uint256(answer);
        } catch {
            // Use fallback price if available
            if (block.timestamp <= lastFallbackUpdate + HEARTBEAT_PERIOD) {
                return fallbackPrice;
            }
            revert InvalidPriceFeed();
        }
    }

    /**
     * @notice Converts a given ETH amount to USDC using the latest price.
     * @param ethAmount Amount of ETH (in wei) to convert.
     * @return usdcAmount Equivalent amount in USDC (6 decimals).
     */
    function ethToUsdc(uint256 ethAmount) external view returns (uint256 usdcAmount) {
        if (ethAmount == 0) return 0;
        
        uint256 ethPrice = getLatestPrice();
        uint256 usdValue = ethAmount * ethPrice; // ETH -> USD
        usdValue = usdValue / (10 ** PRICE_PRECISION); // Adjust precision
        return usdValue / (10 ** (ETH_DECIMALS - USDC_DECIMALS)); // USD -> USDC
    }

    /**
     * @notice Converts a given USDC amount to ETH using the latest price.
     * @param usdcAmount Amount of USDC (in 6 decimals) to convert.
     * @return ethAmount Equivalent amount in ETH (18 decimals).
     */
    function usdcToEth(uint256 usdcAmount) external view returns (uint256 ethAmount) {
        if (usdcAmount == 0) return 0;
        
        uint256 ethPrice = getLatestPrice();
        uint256 scaledAmount = usdcAmount * (10 ** (ETH_DECIMALS - USDC_DECIMALS)); // Scale USDC to ETH decimals
        scaledAmount = scaledAmount * (10 ** PRICE_PRECISION); // Maintain precision
        return scaledAmount / ethPrice; // USD -> ETH
    }

    /**
     * @notice Updates the fallback price manually.
     * @dev Can only be called by the contract owner.
     * @param _fallbackPrice New fallback price to set.
     */
    function updateFallbackPrice(uint256 _fallbackPrice) external onlyOwner {
        if (_fallbackPrice == 0) revert InvalidPrice();
        fallbackPrice = _fallbackPrice;
        lastFallbackUpdate = block.timestamp;
        emit FallbackPriceUpdated(_fallbackPrice);
    }

    /**
     * @notice Checks if the Chainlink price feed is healthy.
     * @return bool True if price feed is healthy, otherwise false.
     */
    function isPriceFeedHealthy() external view returns (bool) {
        try ethUsdPriceFeed.latestRoundData() returns (
            uint80,
            int256 answer,
            uint256,
            uint256 updatedAt,
            uint80
        ) {
            return answer > 0 && 
                   updatedAt != 0 && 
                   block.timestamp <= updatedAt + HEARTBEAT_PERIOD;
        } catch {
            return false;
        }
    }
}
