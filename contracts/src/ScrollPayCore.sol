// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "./IEntryPoint.sol";

/**
 * @title ScrollPayCore
 * @author Chiemezie Agbo
 * @notice This contract facilitates secure and efficient payments using USDC and native crypto.
 * @dev This contract supports native to USDC swaps, delayed withdrawals, and dispute resolution.
 */
contract ScrollPayCore is Ownable, ReentrancyGuard, Pausable {
    // Constants
    uint256 public constant WITHDRAWAL_DELAY = 72 hours;
    uint256 public constant DISPUTE_WINDOW = 72 hours;
    address public immutable WETH9;

    // State Variables
    IERC20 public usdcToken;
    AggregatorV3Interface public ethUsdPriceFeed;
    ISwapRouter public uniswapRouter;
    uint24 public constant poolFee = 3000;

    struct Payment {
        address merchant;
        address client;
        uint256 amount;
        uint256 timestamp;
        bool disputed;
        bool completed;
    }

    struct WithdrawalRequest {
        uint256 amount;
        uint256 requestTime;
    }

    mapping(address => uint256) public merchantBalances;
    mapping(address => WithdrawalRequest) public withdrawalRequests;
    mapping(uint256 => Payment) public payments;
    uint256 public nextPaymentId;

    // Add these to the ScrollPayCore contract
    struct Subscription {
        address merchant;
        address subscriber;
        uint256 amount;
        uint256 interval;
        uint256 lastPayment;
    }

    mapping(uint256 => Subscription) public subscriptions;
    uint256 public nextSubscriptionId;


    // Events
    event PaymentProcessed(uint256 indexed paymentId, address indexed client, address indexed merchant, uint256 amount);
    event WithdrawalRequested(address indexed merchant, uint256 amount, uint256 requestTime);
    event WithdrawalCompleted(address indexed merchant, uint256 amount);
    event DisputeRaised(uint256 indexed paymentId, address indexed client);
    event DisputeResolved(uint256 indexed paymentId, bool merchantFavor);
    event SubscriptionCreated(uint256 indexed subscriptionId, address indexed subscriber, address indexed merchant, uint256 amount, uint256 interval);


    // Errors
    error InsufficientBalance();
    error WithdrawalDelayNotMet();
    error InvalidPaymentId();
    error DisputeWindowClosed();
    error PaymentAlreadyDisputed();
    error UnauthorizedWithdrawal();
    error USDCApprovalFailed();

    IEntryPoint public immutable entryPoint;

    constructor(
        address _usdcToken,
        address _ethUsdPriceFeed,
        address _uniswapRouter,
        address _entryPoint,
        address _WETH9
    ) Ownable(msg.sender) {
        usdcToken = IERC20(_usdcToken);
        ethUsdPriceFeed = AggregatorV3Interface(_ethUsdPriceFeed);
        uniswapRouter = ISwapRouter(_uniswapRouter);
        entryPoint = IEntryPoint(_entryPoint);
        WETH9 = _WETH9;
    }

    /**
     * @notice Process a payment in USDC or Native Currency
     * @param merchant The address of the merchant
     * @param amount The amount to be paid (in USDC if useNative is false)
     * @param useNative True if paying with native currency (ETH), false if paying with USDC
     */
    function processPayment(address merchant, uint256 amount, bool useNative) external payable nonReentrant whenNotPaused {
        if (useNative) {
            uint256 ethUsdPrice = getLatestETHUSDPrice();
            uint256 usdcAmount = (msg.value * ethUsdPrice) / 1e18;
            _swapEthForUsdc(usdcAmount);
            _createPayment(merchant, msg.sender, usdcAmount);
        } else {
            require(usdcToken.transferFrom(msg.sender, address(this), amount), "USDC transfer failed");
            _createPayment(merchant, msg.sender, amount);
        }
    }

    /**
     * @notice Request a withdrawal of funds
     * @param amount The amount of USDC to withdraw
     */
    function requestWithdrawal(uint256 amount) external nonReentrant {
        if (merchantBalances[msg.sender] < amount) revert InsufficientBalance();
        withdrawalRequests[msg.sender] = WithdrawalRequest(amount, block.timestamp);
        emit WithdrawalRequested(msg.sender, amount, block.timestamp);
    }

    /**
     * @notice Complete a withdrawal after the delay period
     */
    function completeWithdrawal() external nonReentrant {
        WithdrawalRequest memory request = withdrawalRequests[msg.sender];
        if (block.timestamp < request.requestTime + WITHDRAWAL_DELAY) revert WithdrawalDelayNotMet();
        if (merchantBalances[msg.sender] < request.amount) revert InsufficientBalance();

        merchantBalances[msg.sender] -= request.amount;
        delete withdrawalRequests[msg.sender];

        require(usdcToken.transfer(msg.sender, request.amount), "USDC transfer failed");
        emit WithdrawalCompleted(msg.sender, request.amount);
    }

    /**
     * @notice Raise a dispute for a payment
     * @param paymentId The ID of the payment to dispute
     */
    function raiseDispute(uint256 paymentId) external nonReentrant {
        Payment storage payment = payments[paymentId];
        if (payment.client != msg.sender) revert UnauthorizedWithdrawal();
        if (block.timestamp > payment.timestamp + DISPUTE_WINDOW) revert DisputeWindowClosed();
        if (payment.disputed) revert PaymentAlreadyDisputed();

        payment.disputed = true;
        emit DisputeRaised(paymentId, msg.sender);
    }

    /**
     * @notice Resolve a dispute (only callable by the contract owner)
     * @param paymentId The ID of the disputed payment
     * @param merchantFavor True if resolved in favor of the merchant, false otherwise
     */
    function resolveDispute(uint256 paymentId, bool merchantFavor) external onlyOwner nonReentrant {
        Payment storage payment = payments[paymentId];
        if (!payment.disputed) revert InvalidPaymentId();

        if (merchantFavor) {
            merchantBalances[payment.merchant] += payment.amount;
        } else {
            require(usdcToken.transfer(payment.client, payment.amount), "USDC transfer failed");
        }

        payment.completed = true;
        payment.disputed = false;
        emit DisputeResolved(paymentId, merchantFavor);
    }

    /**
     * @notice Get the latest ETH/USD price from Chainlink
     * @return The latest ETH/USD price
     */
    function getLatestETHUSDPrice() public view returns (uint256) {
        (, int256 price, , , ) = ethUsdPriceFeed.latestRoundData();
        return uint256(price);
    }

    /**
     * @notice Swap ETH for USDC using Uniswap
     * @param usdcAmount The amount of USDC to receive
     */
    function _swapEthForUsdc(uint256 usdcAmount) internal {
        ISwapRouter.ExactOutputSingleParams memory params = ISwapRouter
            .ExactOutputSingleParams({
                tokenIn: WETH9,
                tokenOut: address(usdcToken),
                fee: poolFee,
                recipient: address(this),
                deadline: block.timestamp,
                amountOut: usdcAmount,
                amountInMaximum: msg.value,
                sqrtPriceLimitX96: 0
            });

        uint256 amountIn = uniswapRouter.exactOutputSingle{value: msg.value}(params);

        if (amountIn < msg.value) {
            // Refund excess ETH to user
            (bool success, ) = msg.sender.call{value: msg.value - amountIn}("");
            require(success, "ETH refund failed");
        }
    }

    function _swapUsdcForEth(uint256 usdcAmount, uint256 minEthAmount) internal returns (uint256) {
        require(usdcToken.approve(address(uniswapRouter), usdcAmount), "USDC approval failed");

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter
            .ExactInputSingleParams({
                tokenIn: address(usdcToken),
                tokenOut: WETH9,
                fee: poolFee,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: usdcAmount,
                amountOutMinimum: minEthAmount,
                sqrtPriceLimitX96: 0
            });

        return uniswapRouter.exactInputSingle(params);
    }

    /**
     * @notice Create a new payment record
     * @param merchant The address of the merchant
     * @param client The address of the client
     * @param amount The amount of the payment in USDC
     */
    function _createPayment(address merchant, address client, uint256 amount) internal {
        uint256 paymentId = nextPaymentId++;
        payments[paymentId] = Payment(merchant, client, amount, block.timestamp, false, false);
        merchantBalances[merchant] += amount;
        emit PaymentProcessed(paymentId, client, merchant, amount);
    }

    // Fallback function to receive ETH
    receive() external payable {}

    // Add this function to the ScrollPayCore contract
    function payForGoods(address merchant, uint256 amount) external nonReentrant whenNotPaused {
        require(usdcToken.transferFrom(msg.sender, address(this), amount), "USDC transfer failed");
        _createPayment(merchant, msg.sender, amount);
    }

    function createSubscription(address merchant, uint256 amount, uint256 interval) external nonReentrant whenNotPaused {
        uint256 subscriptionId = nextSubscriptionId++;
        subscriptions[subscriptionId] = Subscription(merchant, msg.sender, amount, interval, block.timestamp);
        // Initial payment
        require(usdcToken.transferFrom(msg.sender, address(this), amount), "USDC transfer failed");
        _createPayment(merchant, msg.sender, amount);
        emit SubscriptionCreated(subscriptionId, msg.sender, merchant, amount, interval);
    }

    function processSubscriptions() external {
        for (uint256 i = 0; i < nextSubscriptionId; i++) {
            Subscription storage sub = subscriptions[i];
            if (block.timestamp >= sub.lastPayment + sub.interval) {
                if (usdcToken.balanceOf(sub.subscriber) >= sub.amount) {
                    usdcToken.transferFrom(sub.subscriber, address(this), sub.amount);
                    _createPayment(sub.merchant, sub.subscriber, sub.amount);
                    sub.lastPayment = block.timestamp;
                }
            }
        }
    }

}

