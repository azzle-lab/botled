// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BotledRewardSwapper, IAzlUsdOracleLike, IRewardPool} from "../../src/botled/v5near/rewards/BotledRewardSwapper.sol";

contract Tok is ERC20 {
    uint8 immutable d;
    constructor(string memory n, uint8 d_) ERC20(n, n) { d = d_; }
    function decimals() public view override returns (uint8) { return d; }
    function mint(address to, uint256 a) external { _mint(to, a); }
}

/// AZL par price: `usdPerAzl6` USD6 per 1e18 AZL
contract Oracle is IAzlUsdOracleLike {
    uint256 public usdPerAzl6 = 10_000; // $0.01
    bool public valid = true;
    function set(uint256 p, bool v) external { usdPerAzl6 = p; valid = v; }
    function quoteUsdForAzlPar(uint256 a) external view returns (uint256) { return (a * usdPerAzl6 + 1e18 - 1) / 1e18; }
    function isValid() external view returns (bool) { return valid; }
}

contract Pool is IRewardPool {
    IERC20 immutable t;
    uint256 public rewardFund;
    constructor(IERC20 t_) { t = t_; }
    function fundRewards(uint256 a) external { t.transferFrom(msg.sender, address(this), a); rewardFund += a; }
}

/// Stand-in for a DEX router: pulls `inAmt` USDC from msg.sender, sends `outAmt` AZL to `to`.
contract Router {
    Tok immutable usdc;
    Tok immutable azl;
    constructor(Tok u, Tok a) { usdc = u; azl = a; }
    function swap(uint256 inAmt, uint256 outAmt, address to) external {
        usdc.transferFrom(msg.sender, address(this), inAmt);
        azl.mint(to, outAmt);
    }
    function steal(uint256 inAmt) external { usdc.transferFrom(msg.sender, address(0xBEEF), inAmt); }
    function reenter(BotledRewardSwapper s) external { s.sweepAzl(); }
}

contract RewardSwapperTest is Test {
    Tok usdc;
    Tok azl;
    Oracle oracle;
    Pool pool;
    Router router;
    BotledRewardSwapper sw;
    address keeper = address(0xCAFE);

    function setUp() public {
        usdc = new Tok("USDC", 6);
        azl = new Tok("AZL", 18);
        oracle = new Oracle();
        pool = new Pool(azl);
        router = new Router(usdc, azl);
        sw = new BotledRewardSwapper(usdc, azl, oracle, pool, address(router), 300, 1_000e6);
        usdc.mint(address(sw), 100e6); // 50 no-show penalties bridged by 1Click
    }

    function _route(uint256 inAmt, uint256 outAmt) internal view returns (bytes memory) {
        return abi.encodeCall(Router.swap, (inAmt, outAmt, address(sw)));
    }

    function testSwapWithinSlippageFundsPool() public {
        // $100 -> 9_800 AZL at $0.01 = $98 (2% < 3% cap)
        vm.prank(keeper);
        uint256 out = sw.swapAndFund(100e6, _route(100e6, 9_800e18));
        assertEq(out, 9_800e18);
        assertEq(pool.rewardFund(), 9_800e18);
        assertEq(azl.balanceOf(address(pool)), 9_800e18);
        assertEq(usdc.balanceOf(address(sw)), 0);
        assertEq(usdc.allowance(address(sw), address(router)), 0);
    }

    function testRejectsWorseThanCap() public {
        // $100 -> 9_600 AZL = $96 (4% > 3%)
        vm.expectRevert(abi.encodeWithSelector(BotledRewardSwapper.Slippage.selector, 9_600e18, 96e6, 97e6));
        sw.swapAndFund(100e6, _route(100e6, 9_600e18));
    }

    function testOracleMovesFloorNotSpot() public {
        oracle.set(5_000, true); // reference AZL price halves: 9_800 AZL are now worth only $49 for $100 in
        vm.expectRevert();
        sw.swapAndFund(100e6, _route(100e6, 9_800e18));
        oracle.set(10_000, false); // fail-closed oracle
        vm.expectRevert(BotledRewardSwapper.Oracle.selector);
        sw.swapAndFund(100e6, _route(100e6, 9_800e18));
    }

    function testRouteCannotStealOrOverspend() public {
        vm.expectRevert(BotledRewardSwapper.Route.selector); // USDC leaves, no AZL arrives
        sw.swapAndFund(50e6, abi.encodeCall(Router.steal, (50e6)));
        vm.expectRevert(); // allowance is exactly amountIn
        sw.swapAndFund(50e6, _route(60e6, 1e30));
        vm.expectRevert(BotledRewardSwapper.Route.selector); // AZL delivered elsewhere
        sw.swapAndFund(50e6, abi.encodeCall(Router.swap, (50e6, 9_800e18, address(0xBEEF))));
        vm.expectRevert(BotledRewardSwapper.Route.selector); // reentrancy via the router
        sw.swapAndFund(50e6, abi.encodeCall(Router.reenter, (sw)));
        assertEq(usdc.balanceOf(address(sw)), 100e6);
    }

    function testBounds() public {
        vm.expectRevert(BotledRewardSwapper.Bounds.selector);
        sw.swapAndFund(0, "");
        vm.expectRevert(BotledRewardSwapper.Bounds.selector);
        sw.swapAndFund(101e6, _route(101e6, 1e30)); // > balance
        usdc.mint(address(sw), 2_000e6);
        vm.expectRevert(BotledRewardSwapper.Bounds.selector);
        sw.swapAndFund(1_001e6, _route(1_001e6, 1e30)); // > per-call cap
        vm.expectRevert(BotledRewardSwapper.Bounds.selector);
        new BotledRewardSwapper(usdc, azl, oracle, pool, address(router), 501, 1);
        vm.expectRevert(BotledRewardSwapper.Bounds.selector);
        new BotledRewardSwapper(usdc, azl, oracle, pool, address(usdc), 100, 1);
    }

    function testSweepForwardsStrayAzl() public {
        azl.mint(address(sw), 5e18);
        sw.sweepAzl();
        assertEq(pool.rewardFund(), 5e18);
    }

    function testFuzzFloor(uint96 inAmt, uint96 outAzl) public {
        inAmt = uint96(bound(inAmt, 1, 100e6));
        uint256 value = (uint256(outAzl) * 10_000 + 1e18 - 1) / 1e18;
        bytes memory r = _route(inAmt, outAzl);
        if (outAzl == 0 || value < sw.floorUsd6(inAmt)) {
            vm.expectRevert();
            sw.swapAndFund(inAmt, r);
        } else {
            sw.swapAndFund(inAmt, r);
            assertGe(value * 10_000 + 10_000, uint256(inAmt) * 9_700);
        }
    }
}
