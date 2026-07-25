// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IPermit2Minimal {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

contract AgentExecutor {
    error NotOwner();
    error NotAgentOrOwner();
    error Paused();
    error ZeroAddress();
    error BadArrayLength();
    error TokenNotAllowed(address token);
    error AmountZero();
    error AmountTooLarge(address token, uint256 amount, uint256 limit);
    error DailyTradeLimit(uint256 trades, uint256 limit);
    error DailyAmountLimit(address token, uint256 amount, uint256 limit);
    error Cooldown(uint256 readyAt);
    error Expired();
    error OutputTooLow(uint256 received, uint256 minimum);
    error RouterCallFailed(bytes data);
    error SafeTransferFailed(address token);

    address public immutable brokerTba;
    address public immutable router;
    address public immutable permit2;

    address public owner;
    address public agent;
    bool public paused;

    uint256 public cooldownSeconds;
    uint256 public maxDailyTrades;
    uint256 public lastTradeAt;
    uint256 public activeTradeDay;
    uint256 public tradesToday;

    mapping(address => bool) public allowedToken;
    mapping(address => uint256) public maxAmountIn;
    mapping(address => uint256) public maxDailyAmountIn;
    mapping(address => uint256) public tokenDay;
    mapping(address => uint256) public tokenAmountToday;

    uint256 private locked;

    event OwnerUpdated(address indexed oldOwner, address indexed newOwner);
    event AgentUpdated(address indexed oldAgent, address indexed newAgent);
    event PausedUpdated(bool paused);
    event CooldownUpdated(uint256 cooldownSeconds);
    event MaxDailyTradesUpdated(uint256 maxDailyTrades);
    event TokenPolicyUpdated(address indexed token, bool allowed, uint256 maxAmountIn, uint256 maxDailyAmountIn);
    event TradeExecuted(
        address indexed caller,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 minOut,
        uint256 received
    );
    event TokenReturned(address indexed token, uint256 amount);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyAgentOrOwner() {
        if (msg.sender != agent && msg.sender != owner) revert NotAgentOrOwner();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert Paused();
        _;
    }

    modifier nonReentrant() {
        require(locked == 0, "reentrant");
        locked = 1;
        _;
        locked = 0;
    }

    constructor(
        address brokerTba_,
        address router_,
        address permit2_,
        address owner_,
        address agent_,
        address[] memory tokens_,
        uint256[] memory maxAmounts_,
        uint256[] memory maxDailyAmounts_,
        uint256 cooldownSeconds_,
        uint256 maxDailyTrades_
    ) {
        if (
            brokerTba_ == address(0) ||
            router_ == address(0) ||
            permit2_ == address(0) ||
            owner_ == address(0) ||
            agent_ == address(0)
        ) revert ZeroAddress();
        if (tokens_.length != maxAmounts_.length || tokens_.length != maxDailyAmounts_.length) revert BadArrayLength();

        brokerTba = brokerTba_;
        router = router_;
        permit2 = permit2_;
        owner = owner_;
        agent = agent_;
        cooldownSeconds = cooldownSeconds_;
        maxDailyTrades = maxDailyTrades_;

        emit OwnerUpdated(address(0), owner_);
        emit AgentUpdated(address(0), agent_);
        emit CooldownUpdated(cooldownSeconds_);
        emit MaxDailyTradesUpdated(maxDailyTrades_);

        for (uint256 i = 0; i < tokens_.length; i++) {
            _setTokenPolicy(tokens_[i], true, maxAmounts_[i], maxDailyAmounts_[i]);
        }
    }

    function setOwner(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnerUpdated(owner, newOwner);
        owner = newOwner;
    }

    function setAgent(address newAgent) external onlyOwner {
        if (newAgent == address(0)) revert ZeroAddress();
        emit AgentUpdated(agent, newAgent);
        agent = newAgent;
    }

    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PausedUpdated(paused_);
    }

    function setCooldownSeconds(uint256 cooldownSeconds_) external onlyOwner {
        cooldownSeconds = cooldownSeconds_;
        emit CooldownUpdated(cooldownSeconds_);
    }

    function setMaxDailyTrades(uint256 maxDailyTrades_) external onlyOwner {
        maxDailyTrades = maxDailyTrades_;
        emit MaxDailyTradesUpdated(maxDailyTrades_);
    }

    function setTokenPolicy(address token, bool allowed, uint256 maxAmount, uint256 maxDailyAmount) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        allowedToken[token] = allowed;
        maxAmountIn[token] = maxAmount;
        maxDailyAmountIn[token] = maxDailyAmount;
        emit TokenPolicyUpdated(token, allowed, maxAmount, maxDailyAmount);
    }

    function executeTrade(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        bytes calldata routerData,
        uint256 deadline
    ) external onlyAgentOrOwner whenNotPaused nonReentrant returns (uint256 received) {
        if (block.timestamp > deadline) revert Expired();
        if (amountIn == 0 || minOut == 0) revert AmountZero();
        _requireAllowed(tokenIn);
        _requireAllowed(tokenOut);
        _checkLimits(tokenIn, amountIn);

        uint256 beforeOut = _totalTokenBalance(tokenOut);

        _safeTransferFrom(tokenIn, brokerTba, address(this), amountIn);
        _safeApprove(tokenIn, permit2, 0);
        _safeApprove(tokenIn, permit2, amountIn);
        IPermit2Minimal(permit2).approve(tokenIn, router, _toUint160(amountIn), uint48(block.timestamp + 1 hours));

        (bool ok, bytes memory result) = router.call(routerData);

        _safeApprove(tokenIn, permit2, 0);
        IPermit2Minimal(permit2).approve(tokenIn, router, 0, uint48(block.timestamp));

        if (!ok) revert RouterCallFailed(result);

        _returnHeldToken(tokenIn);
        _returnHeldToken(tokenOut);

        uint256 afterOut = _totalTokenBalance(tokenOut);
        received = afterOut > beforeOut ? afterOut - beforeOut : 0;
        if (received < minOut) revert OutputTooLow(received, minOut);

        emit TradeExecuted(msg.sender, tokenIn, tokenOut, amountIn, minOut, received);
    }

    function returnHeldToken(address token) external onlyOwner nonReentrant {
        _returnHeldToken(token);
    }

    function allowanceFromTba(address token) external view returns (uint256) {
        return IERC20Minimal(token).allowance(brokerTba, address(this));
    }

    function _setTokenPolicy(address token, bool allowed, uint256 maxAmount, uint256 maxDailyAmount) internal {
        if (token == address(0)) revert ZeroAddress();
        allowedToken[token] = allowed;
        maxAmountIn[token] = maxAmount;
        maxDailyAmountIn[token] = maxDailyAmount;
        emit TokenPolicyUpdated(token, allowed, maxAmount, maxDailyAmount);
    }

    function _requireAllowed(address token) internal view {
        if (!allowedToken[token]) revert TokenNotAllowed(token);
    }

    function _checkLimits(address tokenIn, uint256 amountIn) internal {
        uint256 maxAmount = maxAmountIn[tokenIn];
        if (maxAmount == 0 || amountIn > maxAmount) revert AmountTooLarge(tokenIn, amountIn, maxAmount);

        uint256 readyAt = lastTradeAt + cooldownSeconds;
        if (lastTradeAt != 0 && block.timestamp < readyAt) revert Cooldown(readyAt);

        uint256 today = block.timestamp / 1 days;
        if (activeTradeDay != today) {
            activeTradeDay = today;
            tradesToday = 0;
        }
        if (maxDailyTrades != 0 && tradesToday + 1 > maxDailyTrades) revert DailyTradeLimit(tradesToday + 1, maxDailyTrades);
        tradesToday += 1;

        if (tokenDay[tokenIn] != today) {
            tokenDay[tokenIn] = today;
            tokenAmountToday[tokenIn] = 0;
        }
        uint256 nextAmount = tokenAmountToday[tokenIn] + amountIn;
        uint256 maxDaily = maxDailyAmountIn[tokenIn];
        if (maxDaily == 0 || nextAmount > maxDaily) revert DailyAmountLimit(tokenIn, nextAmount, maxDaily);
        tokenAmountToday[tokenIn] = nextAmount;

        lastTradeAt = block.timestamp;
    }

    function _totalTokenBalance(address token) internal view returns (uint256) {
        return IERC20Minimal(token).balanceOf(brokerTba) + IERC20Minimal(token).balanceOf(address(this));
    }

    function _returnHeldToken(address token) internal {
        uint256 balance = IERC20Minimal(token).balanceOf(address(this));
        if (balance == 0) return;
        _safeTransfer(token, brokerTba, balance);
        emit TokenReturned(token, balance);
    }

    function _safeTransfer(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(IERC20Minimal.transfer.selector, to, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert SafeTransferFailed(token);
    }

    function _safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory data) =
            token.call(abi.encodeWithSelector(IERC20Minimal.transferFrom.selector, from, to, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert SafeTransferFailed(token);
    }

    function _safeApprove(address token, address spender, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(IERC20Minimal.approve.selector, spender, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert SafeTransferFailed(token);
    }

    function _toUint160(uint256 value) internal pure returns (uint160) {
        if (value > type(uint160).max) revert AmountTooLarge(address(0), value, type(uint160).max);
        return uint160(value);
    }
}
