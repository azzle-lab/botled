// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @dev Subset of Azzle's AzlUsdOracle (delayed AZL/ETH reference x Chainlink ETH/USD, fail-closed).
interface IAzlUsdOracleLike {
    function quoteUsdForAzlPar(uint256 azlAmount) external view returns (uint256 usdAmount6);
    function isValid() external view returns (bool);
}

interface IRewardPool {
    function fundRewards(uint256 amount) external;
}

/// @title BotledRewardSwapper — no-show penalties (USDC) -> AZL runner rewards, non-custodial and bounded
/// @notice NEAR side: BotledRegistry.bridge_penalties sends the penalty USDC through NEAR Intents 1Click to THIS
///         contract on Base (recipient, assets, refund target and a USDC->USDC slippage cap are enforced on NEAR
///         against a 1Click-signed quote). Base side: anyone (a keeper) calls `swapAndFund` with router calldata
///         (e.g. a Uniswap / aggregator route). The contract does not trust the calldata; it only checks the result:
///           - at most `amountIn` USDC leaves, approval is reset to 0 afterwards;
///           - the AZL received is worth >= (1 - maxSlippageBps) of the USDC spent at the Azzle oracle's PAR price
///             (delayed TWAP reference, not the spot pool -> a sandwich cannot move the floor);
///           - every AZL received goes to `pool.fundRewards` in the same transaction.
///         There is no owner, no withdraw and no parameter setter: funds can only become runner rewards.
contract BotledRewardSwapper is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 public constant MAX_SLIPPAGE_CAP_BPS = 500;
    uint256 internal constant BPS = 10_000;

    IERC20 public immutable usdc;
    IERC20 public immutable azl;
    IAzlUsdOracleLike public immutable oracle;
    IRewardPool public immutable pool;
    address public immutable router;
    uint16 public immutable maxSlippageBps;
    /// @notice per-call cap: bounds the value exposed to one route even if the oracle reference were stale-but-valid
    uint256 public immutable maxInPerCall;

    error Bounds();
    error Oracle();
    error Route();
    error Slippage(uint256 azlOut, uint256 usdValue6, uint256 floor6);

    event Swapped(address indexed keeper, uint256 usdcIn, uint256 azlOut, uint256 parUsd6);

    constructor(
        IERC20 usdc_,
        IERC20 azl_,
        IAzlUsdOracleLike oracle_,
        IRewardPool pool_,
        address router_,
        uint16 maxSlippageBps_,
        uint256 maxInPerCall_
    ) {
        if (maxSlippageBps_ > MAX_SLIPPAGE_CAP_BPS || maxInPerCall_ == 0 || router_.code.length == 0) revert Bounds();
        if (router_ == address(usdc_) || router_ == address(azl_) || router_ == address(pool_)) revert Bounds();
        usdc = usdc_;
        azl = azl_;
        oracle = oracle_;
        pool = pool_;
        router = router_;
        maxSlippageBps = maxSlippageBps_;
        maxInPerCall = maxInPerCall_;
    }

    /// @notice Lowest AZL value (USD6 at the oracle's par price) a swap of `usdcIn` must return.
    function floorUsd6(uint256 usdcIn) public view returns (uint256) {
        return usdcIn * (BPS - maxSlippageBps) / BPS;
    }

    /// @param amountIn  USDC the route may spend (<= balance, <= maxInPerCall)
    /// @param routerData calldata for `router`; must deliver AZL to this contract
    function swapAndFund(uint256 amountIn, bytes calldata routerData) external nonReentrant returns (uint256 azlOut) {
        if (amountIn == 0 || amountIn > maxInPerCall || amountIn > usdc.balanceOf(address(this))) revert Bounds();
        if (!oracle.isValid()) revert Oracle();
        uint256 u0 = usdc.balanceOf(address(this));
        uint256 a0 = azl.balanceOf(address(this));

        usdc.forceApprove(router, amountIn);
        (bool ok,) = router.call(routerData);
        if (!ok) revert Route();
        usdc.forceApprove(router, 0);

        uint256 spent = u0 - usdc.balanceOf(address(this)); // underflow (revert) if the route added USDC
        azlOut = azl.balanceOf(address(this)) - a0;
        if (spent == 0 || spent > amountIn || azlOut == 0) revert Route();
        uint256 value6 = oracle.quoteUsdForAzlPar(azlOut);
        uint256 floor6 = floorUsd6(spent);
        if (value6 < floor6) revert Slippage(azlOut, value6, floor6);

        azl.forceApprove(address(pool), azlOut);
        pool.fundRewards(azlOut);
        emit Swapped(msg.sender, spent, azlOut, value6);
    }

    /// @notice AZL that reached this contract any other way (e.g. a route that over-delivered earlier) is also
    ///         forwarded to the reward pool, permissionlessly.
    function sweepAzl() external nonReentrant {
        uint256 b = azl.balanceOf(address(this));
        if (b == 0) revert Bounds();
        azl.forceApprove(address(pool), b);
        pool.fundRewards(b);
    }
}
