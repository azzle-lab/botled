// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ArbitrationModuleV2} from "azzle-v2/ArbitrationModuleV2.sol";
import {VerifierBondVaultV2} from "azzle-v2/VerifierBondVaultV2.sol";
import {BotledPanelOwner, IPanelModule} from "../src/botled/BotledPanelOwner.sol";
import {AZL, MockTreasury, MockEscrow, MockRep, MockRegistry} from "./Botled.t.sol";

/// @dev A contract member that cannot receive ETH (exercises the claim() fallback).
contract NoReceiveAgent {
    function bondBoth(IERC20 azl, VerifierBondVaultV2 mv, VerifierBondVaultV2 sv) external {
        azl.approve(address(mv), 1_000e18);
        azl.approve(address(sv), 10_000e18);
        mv.bond(1_000e18);
        sv.bond(10_000e18);
    }
    function join(BotledPanelOwner o) external payable { o.join{value: msg.value}(); }
    function leave(BotledPanelOwner o) external { o.leave(); }
    function claim(BotledPanelOwner o) external { o.claim(); }
}

/// @dev Shared assertions so unit (local real Azzle contracts + mocks) and fork (live Base) run the same flows.
abstract contract PanelOwnerFlows is Test {
    uint256 constant PFAND = 0.002 ether;
    address safe;
    IERC20 azl;
    ArbitrationModuleV2 micro;
    ArbitrationModuleV2 standard;
    VerifierBondVaultV2 mv;
    VerifierBondVaultV2 sv;
    BotledPanelOwner po;
    address agent = makeAddr("agent");
    address keeper = makeAddr("keeper");
    address stranger = makeAddr("stranger");

    function _fund(address to, uint256 amount) internal virtual;

    function _deployOwner() internal {
        po = new BotledPanelOwner(safe, IPanelModule(address(micro)), IPanelModule(address(standard)), PFAND, 128, address(0));
    }

    function _handOver() internal {
        vm.startPrank(safe);
        micro.transferOwnership(address(po));
        standard.transferOwnership(address(po));
        vm.stopPrank();
        po.acceptModuleOwnership();
        assertEq(micro.owner(), address(po));
        assertEq(standard.owner(), address(po));
    }

    function _bond(address a) internal {
        _fund(a, 11_000e18);
        vm.startPrank(a);
        azl.approve(address(mv), 1_000e18);
        azl.approve(address(sv), 10_000e18);
        mv.bond(1_000e18);
        sv.bond(10_000e18);
        vm.stopPrank();
    }

    function _join(address a) internal {
        vm.deal(a, 1 ether);
        vm.prank(a);
        po.join{value: PFAND}();
    }

    // ---------------------------------------------------------------- flows

    function _flowJoinBoth() internal {
        _bond(agent);
        uint256 ml = micro.panelLength();
        uint256 sl = standard.panelLength();
        _join(agent);
        assertTrue(micro.authorized(agent) && standard.authorized(agent));
        assertEq(micro.panelMember(ml), agent);
        assertEq(standard.panelMember(sl), agent);
        assertTrue(po.isSeated(agent));
        assertEq(po.seatCount(), 1);
        assertEq(address(po).balance, PFAND);
    }

    function _flowDoubleJoinRejected() internal {
        _flowJoinBoth();
        vm.prank(agent);
        vm.expectRevert(BotledPanelOwner.AlreadySeated.selector);
        po.join{value: PFAND}();
    }

    function _flowKickAfterWithdraw() internal {
        _flowJoinBoth();
        vm.prank(keeper);
        vm.expectRevert(BotledPanelOwner.StillEligible.selector);
        po.kick(agent);
        // Agent pulls its standard bond (allowed: other eligible panel members exist).
        vm.prank(agent);
        sv.scheduleWithdrawal();
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(agent);
        sv.withdraw(10_000e18);
        assertFalse(sv.isEligible(agent));
        assertTrue(po.kickable(agent));
        uint256 before = keeper.balance;
        vm.prank(keeper);
        po.kick(agent);
        assertEq(keeper.balance - before, PFAND, "pfand to kicker");
        assertFalse(micro.authorized(agent) || standard.authorized(agent));
        assertFalse(po.isSeated(agent));
        assertEq(po.seatCount(), 0);
        assertEq(address(po).balance, 0);
    }

    /// @dev `assign` / `release` pranked as the module = exactly what openDispute / rule do in the vault.
    function _flowLeaveWithAndWithoutDispute() internal {
        _flowJoinBoth();
        vm.prank(address(micro));
        mv.assign(agent);
        assertTrue(mv.canRelease(agent));
        vm.prank(agent);
        vm.expectRevert(BotledPanelOwner.MemberBusy.selector);
        po.leave();
        vm.prank(keeper);
        vm.expectRevert(BotledPanelOwner.MemberBusy.selector); // busy => ineligible, still not kickable
        po.kick(agent);
        vm.prank(address(micro));
        mv.release(agent);
        uint256 before = agent.balance;
        vm.prank(agent);
        po.leave();
        assertEq(agent.balance - before, PFAND, "refund");
        assertFalse(micro.authorized(agent) || standard.authorized(agent));
        // after leaving the agent can exit its bonds normally
        vm.startPrank(agent);
        mv.scheduleWithdrawal();
        sv.scheduleWithdrawal();
        vm.stopPrank();
    }

    function _flowTimelockedOwnerCall() internal {
        address extra = makeAddr("cage");
        bytes memory data = abi.encodeCall(ArbitrationModuleV2.addPanelMember, (extra));
        vm.prank(stranger);
        vm.expectRevert(BotledPanelOwner.OnlySafe.selector);
        po.schedule(address(micro), data, bytes32(0));
        vm.prank(safe);
        vm.expectRevert(BotledPanelOwner.BadTarget.selector);
        po.schedule(address(mv), data, bytes32(0));
        vm.prank(safe);
        bytes32 id = po.schedule(address(micro), data, bytes32(0));
        vm.warp(block.timestamp + 7 days - 1);
        vm.prank(safe);
        vm.expectRevert(BotledPanelOwner.NotReady.selector);
        po.execute(address(micro), data, bytes32(0));
        vm.warp(block.timestamp + 1);
        vm.prank(stranger);
        vm.expectRevert(BotledPanelOwner.OnlySafe.selector);
        po.execute(address(micro), data, bytes32(0));
        vm.prank(safe);
        po.execute(address(micro), data, bytes32(0));
        assertTrue(micro.authorized(extra));
        assertEq(po.readyAt(id), 0);
        // replay impossible
        vm.prank(safe);
        vm.expectRevert(BotledPanelOwner.UnknownCall.selector);
        po.execute(address(micro), data, bytes32(0));
        // cancel
        bytes memory rm = abi.encodeCall(ArbitrationModuleV2.removePanelMember, (extra));
        vm.prank(safe);
        bytes32 id2 = po.schedule(address(micro), rm, bytes32(uint256(1)));
        vm.prank(stranger);
        vm.expectRevert(BotledPanelOwner.OnlySafe.selector);
        po.cancel(id2);
        vm.prank(safe);
        po.cancel(id2);
        vm.warp(block.timestamp + 8 days);
        vm.prank(safe);
        vm.expectRevert(BotledPanelOwner.UnknownCall.selector);
        po.execute(address(micro), rm, bytes32(uint256(1)));
    }

    function _flowHandBack() internal {
        _flowJoinBoth();
        bytes memory d = abi.encodeWithSignature("transferOwnership(address)", safe);
        vm.startPrank(safe);
        po.schedule(address(micro), d, "back");
        po.schedule(address(standard), d, "back");
        vm.warp(block.timestamp + 7 days);
        po.execute(address(micro), d, "back");
        po.execute(address(standard), d, "back");
        micro.acceptOwnership();
        standard.acceptOwnership();
        vm.stopPrank();
        assertEq(micro.owner(), safe);
        assertEq(standard.owner(), safe);
        // joins stop; an existing seat can still recover its pfand (governance owns removal now)
        address b = makeAddr("late");
        _bond(b);
        vm.deal(b, 1 ether);
        vm.prank(b);
        vm.expectRevert(BotledPanelOwner.NotModuleOwner.selector);
        po.join{value: PFAND}();
        uint256 before = agent.balance;
        vm.prank(agent);
        po.leave();
        assertEq(agent.balance - before, PFAND);
        assertTrue(micro.authorized(agent), "removal is governance's job after hand-back");
    }

    function _flowNonSafeCannotOwn() internal {
        address first = micro.panelMember(0);
        vm.startPrank(stranger);
        vm.expectRevert();
        micro.addPanelMember(stranger);
        vm.expectRevert();
        standard.removePanelMember(first);
        vm.expectRevert();
        micro.transferOwnership(stranger);
        vm.expectRevert(BotledPanelOwner.OnlySelf.selector);
        po.setConfig(1, 1, stranger);
        vm.stopPrank();
        vm.prank(safe); // even the Safe cannot skip the timelock
        vm.expectRevert(BotledPanelOwner.OnlySelf.selector);
        po.setConfig(1, 1, safe);
        vm.prank(safe);
        vm.expectRevert(); // Safe no longer owns the module directly
        micro.addPanelMember(stranger);
    }
}

/// @notice Unit tests: the real ArbitrationModuleV2 + VerifierBondVaultV2 code, mocked registry/escrow/reputation.
contract BotledPanelOwnerUnitTest is PanelOwnerFlows {
    AZL token;
    MockRegistry reg;

    function _fund(address to, uint256 amount) internal override { token.mint(to, amount); }

    function setUp() public {
        safe = makeAddr("safe");
        token = new AZL();
        azl = IERC20(address(token));
        MockTreasury tr = new MockTreasury();
        MockEscrow es = new MockEscrow();
        MockRep rep = new MockRep();
        reg = new MockRegistry();
        address a = makeAddr("old1");
        address b = makeAddr("old2");
        mv = new VerifierBondVaultV2(address(token), 1_000e18, 7 days, address(tr), safe);
        sv = new VerifierBondVaultV2(address(token), 10_000e18, 7 days, address(tr), safe);
        address[] memory p = new address[](2);
        (p[0], p[1]) = (a, b);
        micro = new ArbitrationModuleV2(address(reg), address(es), address(rep), address(mv), address(tr), 3 days, 2 days, 1000, p, safe);
        standard = new ArbitrationModuleV2(address(reg), address(es), address(rep), address(sv), address(tr), 3 days, 2 days, 1000, p, safe);
        vm.startPrank(safe);
        mv.configureArbitration(address(micro));
        sv.configureArbitration(address(standard));
        vm.stopPrank();
        _bond(a);
        _bond(b);
        // mirror Base: the two original members hold 10k AZL in the micro vault too (multi-case capacity)
        _topUpMicro(a, 9_000e18);
        _topUpMicro(b, 9_000e18);
        _deployOwner();
        _handOver();
    }

    function _topUpMicro(address a, uint256 amt) internal {
        _fund(a, amt);
        vm.startPrank(a);
        azl.approve(address(mv), amt);
        mv.bond(amt);
        vm.stopPrank();
    }

    function testJoinBothPanels() public { _flowJoinBoth(); }
    function testDoubleJoinRejected() public { _flowDoubleJoinRejected(); }
    function testKickAfterBondWithdrawn() public { _flowKickAfterWithdraw(); }
    function testLeaveWithAndWithoutOpenDispute() public { _flowLeaveWithAndWithoutDispute(); }
    function testTimelockedOwnerCall() public { _flowTimelockedOwnerCall(); }
    function testOwnershipHandBack() public { _flowHandBack(); }
    function testNonSafeCannotCallOwnerFunctions() public { _flowNonSafeCannotOwn(); }

    function testJoinRequiresPfandAndBothBonds() public {
        _fund(agent, 1_000e18);
        vm.startPrank(agent);
        azl.approve(address(mv), 1_000e18);
        mv.bond(1_000e18);
        vm.deal(agent, 1 ether);
        vm.expectRevert(BotledPanelOwner.BadPfand.selector);
        po.join{value: 0.001 ether}();
        vm.expectRevert(BotledPanelOwner.NotEligible.selector); // micro only, no standard bond
        po.join{value: PFAND}();
        vm.stopPrank();
    }

    function testExistingMemberCannotTakeSeat() public {
        address old = micro.panelMember(0);
        vm.deal(old, 1 ether);
        vm.prank(old);
        vm.expectRevert(BotledPanelOwner.AlreadyOnPanel.selector);
        po.join{value: PFAND}();
    }

    function testJoinBeforeOwnershipAccepted() public {
        BotledPanelOwner po2 =
            new BotledPanelOwner(safe, IPanelModule(address(micro)), IPanelModule(address(standard)), PFAND, 128, address(0));
        _bond(agent);
        vm.deal(agent, 1 ether);
        vm.prank(agent);
        vm.expectRevert(BotledPanelOwner.NotModuleOwner.selector);
        po2.join{value: PFAND}();
    }

    function testPanelCap() public {
        bytes memory d = abi.encodeCall(BotledPanelOwner.setConfig, (PFAND, 3, address(0)));
        vm.startPrank(safe);
        po.schedule(address(po), d, 0);
        vm.warp(block.timestamp + 7 days);
        po.execute(address(po), d, 0);
        vm.stopPrank();
        _flowJoinBoth(); // panel length 2 -> 3
        address b = makeAddr("b");
        _bond(b);
        vm.deal(b, 1 ether);
        vm.prank(b);
        vm.expectRevert(BotledPanelOwner.PanelFull.selector);
        po.join{value: PFAND}();
    }

    function testForfeitToTreasuryAndPfandChangeKeepsOldSeats() public {
        address treasury = makeAddr("treasury");
        _flowJoinBoth();
        bytes memory d = abi.encodeCall(BotledPanelOwner.setConfig, (0.005 ether, 128, treasury));
        vm.startPrank(safe);
        po.schedule(address(po), d, 0);
        vm.warp(block.timestamp + 7 days);
        po.execute(address(po), d, 0);
        vm.stopPrank();
        assertEq(po.pfand(), 0.005 ether);
        vm.prank(agent);
        mv.scheduleWithdrawal(); // ineligible in micro
        vm.prank(keeper);
        po.kick(agent);
        assertEq(treasury.balance, PFAND, "old seat forfeits the pfand it paid");
        assertEq(keeper.balance, 0);
    }

    function testRealDisputeBlocksLeaveUntilRuled() public {
        _flowJoinBoth(); // micro panel: old1, old2, agent ; cursor 0
        reg.open(micro, 1, keccak256("e1")); // -> old1
        reg.open(micro, 2, keccak256("e2")); // -> old2
        reg.open(micro, 3, keccak256("e3")); // -> agent
        (,, address arb,,,,,,,) = micro.disputes(3);
        assertEq(arb, agent);
        vm.prank(agent);
        vm.expectRevert(BotledPanelOwner.MemberBusy.selector);
        po.leave();
        vm.warp(block.timestamp + 3 days + 1);
        vm.prank(agent);
        micro.rule(3, ArbitrationModuleV2.Outcome.POSTER_WINS, 0);
        vm.prank(agent);
        po.leave();
        assertFalse(micro.authorized(agent));
    }

    function testRefundFallbackToClaim() public {
        NoReceiveAgent c = new NoReceiveAgent();
        _fund(address(c), 11_000e18);
        c.bondBoth(azl, mv, sv);
        vm.deal(address(this), 1 ether);
        c.join{value: PFAND}(po);
        c.leave(po);
        assertEq(po.claimable(address(c)), PFAND);
        vm.expectRevert(); // still cannot receive
        c.claim(po);
    }

    function testNoEthForwardingByGovernance() public {
        _flowJoinBoth();
        // execute() has no value parameter; the only ETH exits are leave/kick/claim.
        bytes memory d = abi.encodeWithSignature("transferOwnership(address)", stranger);
        vm.startPrank(safe);
        po.schedule(address(micro), d, 0);
        vm.warp(block.timestamp + 7 days);
        po.execute(address(micro), d, 0);
        vm.stopPrank();
        assertEq(address(po).balance, PFAND);
        assertEq(micro.pendingOwner(), stranger);
    }
}

/// @notice Fork tests against the live Base modules/vaults. Run with FORK_BASE=true.
contract BotledPanelOwnerForkTest is PanelOwnerFlows {
    address constant SAFE = 0xB459145b74Ca4B198f73C0d573a161e85CA76D27;
    address constant MICRO = 0x905E561B44E76fdeAF5F41Bc2c46ebCE4E5E02fE;
    address constant STANDARD = 0x1003592A2eeF71b15A21457910007b38B0e2027A;
    address constant AZL_TOKEN = 0x931517E9502F9d52CDF6F5AC7fca7925e2A1BBA3;
    address constant AZL_WHALE = 0x3D5eb1F648F495fAEFaeBa0dE74A5c52b6602F5D; // Botled deployer (4.8M AZL)
    bool on;

    function _fund(address to, uint256 amount) internal override {
        vm.prank(AZL_WHALE);
        azl.transfer(to, amount);
    }

    function setUp() public {
        on = vm.envOr("FORK_BASE", false);
        if (!on) return;
        vm.createSelectFork(vm.envOr("BASE_RPC", string("https://mainnet.base.org")));
        safe = SAFE;
        azl = IERC20(AZL_TOKEN);
        micro = ArbitrationModuleV2(MICRO);
        standard = ArbitrationModuleV2(STANDARD);
        mv = VerifierBondVaultV2(address(micro.bonds()));
        sv = VerifierBondVaultV2(address(standard.bonds()));
        assertEq(address(mv), 0x54242151DDCe196314fba21FA630bF62D56a14B3);
        assertEq(address(sv), 0xFeF0722d2f3ba0FEb59b3fd5dCAaF49e69BD5387);
        assertEq(micro.owner(), SAFE);
        assertEq(standard.owner(), SAFE);
        uint256 g = gasleft();
        _deployOwner();
        emit log_named_uint("BotledPanelOwner deploy gas (approx, excl. intrinsic)", g - gasleft());
        _handOver();
    }

    function testForkJoinBothPanels() public { if (on) _flowJoinBoth(); }
    function testForkDoubleJoinRejected() public { if (on) _flowDoubleJoinRejected(); }
    function testForkKickAfterBondWithdrawn() public { if (on) _flowKickAfterWithdraw(); }
    function testForkLeaveWithAndWithoutOpenDispute() public { if (on) _flowLeaveWithAndWithoutDispute(); }
    function testForkTimelockedOwnerCall() public { if (on) _flowTimelockedOwnerCall(); }
    function testForkOwnershipHandBack() public { if (on) _flowHandBack(); }
    function testForkNonSafeCannotCallOwnerFunctions() public { if (on) _flowNonSafeCannotOwn(); }

    function testForkJoinGas() public {
        if (!on) return;
        _bond(agent);
        vm.deal(agent, 1 ether);
        vm.prank(agent);
        uint256 g = gasleft();
        po.join{value: PFAND}();
        emit log_named_uint("join gas", g - gasleft());
        vm.prank(agent);
        g = gasleft();
        po.leave();
        emit log_named_uint("leave gas", g - gasleft());
    }
}
