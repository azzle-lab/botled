// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm, stdStorage, StdStorage} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ArbitrationModuleV2} from "azzle-v2/ArbitrationModuleV2.sol";
import {VerifierBondVaultV2} from "azzle-v2/VerifierBondVaultV2.sol";
import {BotledPanelOwner, IPanelModule} from "../src/botled/BotledPanelOwner.sol";
import {BotledConfig} from "../src/botled/BotledConfig.sol";
import {BotledRunnerPool} from "../src/botled/BotledRunnerPool.sol";
import {BotledCageV5} from "../src/botled/v5/BotledCageV5.sol";
import {BotledFactoryV5} from "../src/botled/v5/BotledFactoryV5.sol";
import {IAzzleArbitrationV2} from "../src/botled/interfaces/IAzzle.sol";
import {AZL, MockTreasury, MockEscrow, MockRep, MockRegistry, MockVrfWrapper} from "./Botled.t.sol";

/// @dev Shared v5 flows: run against local real Azzle modules (unit) and the live Base contracts (fork).
abstract contract V5Flows is Test {
    uint256 constant PFAND = 0.002 ether;
    uint8 constant POSTER_WINS = 1;
    uint8 constant WORKER_WINS = 2;
    uint8 constant SPLIT = 3;

    IERC20 azl;
    BotledConfig config;
    BotledRunnerPool pool;
    BotledFactoryV5 factory;
    BotledPanelOwner po;
    ArbitrationModuleV2 micro;
    ArbitrationModuleV2 standard;
    VerifierBondVaultV2 mv;
    VerifierBondVaultV2 sv;
    address vrfWrapper;
    address operator = makeAddr("operator");
    address keeper = makeAddr("keeper");
    address[] runners;
    BotledCageV5 cage;

    function _fund(address to, uint256 amount) internal virtual;
    /// @dev opens a real dispute on `m` that the round-robin assigns to the cage; returns the task id.
    function _dispute(ArbitrationModuleV2 m) internal virtual returns (uint256 taskId);
    function _party(ArbitrationModuleV2 m, uint256 taskId) internal view virtual returns (address poster, address worker);

    // ---------------------------------------------------------------- deploy (mirrors script/DeployBotledV5.s.sol)

    function _deployV5(address config_, address vrf_, address panelOwner_) internal {
        // pool first (its `config` slot = the factory deployed right after it), then factory
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        pool = new BotledRunnerPool(predicted, address(azl), vrf_, 100e18, 7 days, 100_000, 70_000, 3);
        factory = new BotledFactoryV5(BotledConfig(config_), address(pool), panelOwner_, address(0), address(0));
        assertEq(address(factory), predicted, "anchor");
        vrfWrapper = vrf_;
        vm.deal(address(pool), 1 ether); // VRF fund
    }

    function _addRunners(uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            address r = vm.addr(0xB0700 + i);
            runners.push(r);
            _fund(r, 1_000e18);
            vm.startPrank(r);
            azl.approve(address(pool), 1_000e18);
            pool.registerRunner(1_000e18);
            vm.stopPrank();
        }
    }

    function _createAndSeat() internal {
        vm.prank(operator);
        cage = BotledCageV5(payable(factory.deployCage(0, "op-1")));
        assertEq(cage.operator(), operator);
        assertTrue(factory.isCage(address(cage)));
        _fund(operator, 11_000e18);
        vm.deal(operator, 1 ether);
        vm.startPrank(operator);
        azl.approve(address(cage), 11_000e18);
        cage.seat{value: PFAND}(0, 0);
        vm.stopPrank();
        assertTrue(po.isSeated(address(cage)), "seated");
        assertTrue(micro.authorized(address(cage)) && standard.authorized(address(cage)), "on both panels");
        assertEq(mv.bonds(address(cage)), 1_000e18);
        assertEq(sv.bonds(address(cage)), 10_000e18);
        assertEq(azl.balanceOf(operator), 0);
    }

    // ---------------------------------------------------------------- jury driver

    function _requestIdFromLogs(Vm.Log[] memory logs) internal view returns (uint256 id) {
        bytes32 sig = keccak256("DrawRequested(address,uint256,uint256,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(pool) && logs[i].topics[0] == sig) (id,) = abi.decode(logs[i].data, (uint256, uint256));
        }
        require(id != 0, "no DrawRequested");
    }

    function _fulfill(uint256 requestId, uint256 word) internal {
        uint256[] memory w = new uint256[](1);
        w[0] = word;
        vm.prank(vrfWrapper);
        pool.rawFulfillRandomWords(requestId, w);
    }

    function _commitment(address m, uint256 taskId, uint8 r, address runner, uint8 o, uint16 b, uint8 lane, bytes32 salt)
        internal
        view
        returns (bytes32)
    {
        bytes32 ih = cage.getCase(m, taskId).inputHash;
        return keccak256(abi.encode(address(cage), m, taskId, r, runner, ih, o, b, lane, keccak256(abi.encode(runner, r)), salt));
    }

    /// @dev Every drawn runner votes (o[i], b[i]) with lane i % 2; returns the drawn list.
    function _juryVotes(address m, uint256 taskId, uint8[] memory o, uint16[] memory b) internal returns (address[] memory list) {
        uint8 r = cage.getCase(m, taskId).round;
        list = pool.drawnRunners(address(cage), cage.drawId(m, taskId, r));
        for (uint256 i; i < list.length; ++i) {
            bytes32 h = _commitment(m, taskId, r, list[i], o[i], b[i], uint8(i % 2), bytes32(i + 1));
            vm.prank(list[i]);
            cage.commit(m, taskId, h);
        }
        (uint256 commitEnd,) = cage.windows(m, taskId);
        vm.warp(commitEnd + 1);
        for (uint256 i; i < list.length; ++i) {
            vm.prank(list[i]);
            cage.reveal(m, taskId, o[i], b[i], uint8(i % 2), keccak256(abi.encode(list[i], r)), bytes32(i + 1));
        }
    }

    function _uniform(uint256 n, uint8 o, uint16 b) internal pure returns (uint8[] memory os, uint16[] memory bs) {
        os = new uint8[](n);
        bs = new uint16[](n);
        for (uint256 i; i < n; ++i) (os[i], bs[i]) = (o, b);
    }

    function _open(address m, uint256 taskId, uint256 word) internal {
        (,,,,, uint64 evDeadline,,,,) = ArbitrationModuleV2(m).disputes(taskId);
        if (block.timestamp <= evDeadline) vm.warp(evDeadline + 1);
        vm.recordLogs();
        vm.prank(keeper);
        cage.openCase(m, taskId);
        _fulfill(_requestIdFromLogs(vm.getRecordedLogs()), word);
    }

    /// @dev Full unanimous round 1 -> appeal window -> finalize -> Azzle rule() on module `m`.
    function _ruleUnanimous(address m, uint256 taskId, uint8 o, uint16 b, uint256 word) internal {
        _open(m, taskId, word);
        (uint8[] memory os, uint16[] memory bs) = _uniform(3, o, b);
        _juryVotes(m, taskId, os, bs);
        vm.prank(keeper);
        cage.closeRound(m, taskId);
        BotledCageV5.Case memory c = cage.getCase(m, taskId);
        assertEq(uint8(c.phase), 2, "appeal phase");
        vm.warp(c.deadline + 1);
        vm.prank(keeper);
        cage.finalize(m, taskId);
        (,,,,,,, uint8 status, uint8 outcome,) = IAzzleArbitrationV2(m).disputes(taskId);
        assertEq(status, 3, "settled on Azzle");
        assertEq(outcome, o, "routed ruling");
        assertEq(uint8(cage.getCase(m, taskId).phase), 3);
    }

    // ---------------------------------------------------------------- flows

    function _flowMicroAndStandard() internal {
        _createAndSeat();
        uint256 tm = _dispute(micro);
        uint256 ts = _dispute(standard);
        (,, address am,,,,,,,) = micro.disputes(tm);
        (,, address as_,,,,,,,) = standard.disputes(ts);
        assertEq(am, address(cage), "micro dispute on v5 cage");
        assertEq(as_, address(cage), "standard dispute on v5 cage");
        // seat cannot be left while a dispute is assigned
        vm.prank(operator);
        vm.expectRevert(BotledPanelOwner.MemberBusy.selector);
        cage.unseat();

        _ruleUnanimous(address(micro), tm, POSTER_WINS, 0, 11);
        _ruleUnanimous(address(standard), ts, WORKER_WINS, 10_000, 22);
        assertFalse(mv.canRelease(address(cage)) || sv.canRelease(address(cage)), "assignments released");
        // drawn runners were released in the pool
        for (uint256 i; i < runners.length; ++i) {
            (, uint32 active,,) = pool.runners(runners[i]);
            assertEq(active, 0);
        }
        _flowExit();
    }

    /// @dev Azzle refuses to remove/unbond the LAST eligible panel member; make sure someone else is eligible.
    function _beforeExit() internal virtual;

    function _flowExit() internal {
        _beforeExit();
        uint256 ethBefore = operator.balance;
        vm.prank(operator);
        cage.exit(); // unseat + scheduleExit
        assertEq(operator.balance - ethBefore, PFAND, "pfand back");
        assertFalse(po.isSeated(address(cage)));
        assertFalse(micro.authorized(address(cage)) || standard.authorized(address(cage)));
        vm.warp(block.timestamp + 7 days);
        vm.startPrank(operator);
        cage.withdrawBond(0, 0);
        cage.withdrawBond(1, 0);
        vm.stopPrank();
        assertEq(azl.balanceOf(operator), 11_000e18, "bonds back");
    }

    function _flowAppealOnStandard() internal {
        _createAndSeat();
        uint256 ts = _dispute(standard);
        address m = address(standard);
        _open(m, ts, 7);
        // round 1: 2x POSTER_WINS (lanes 0,1) vs 1x WORKER_WINS -> POSTER_WINS stands
        uint8[] memory os = new uint8[](3);
        uint16[] memory bs = new uint16[](3);
        (os[0], os[1], os[2], bs[2]) = (POSTER_WINS, POSTER_WINS, WORKER_WINS, 10_000);
        address[] memory r1 = _juryVotes(m, ts, os, bs);
        vm.prank(keeper);
        cage.closeRound(m, ts);
        assertTrue(cage.getCase(m, ts).hasResult);
        // worker appeals with 200 AZL bond -> 7 jurors
        (, address worker) = _party(standard, ts);
        uint256 bond = cage.appealBond(m, ts, 2);
        _fund(worker, bond);
        vm.startPrank(worker);
        azl.approve(address(cage), bond);
        vm.recordLogs();
        cage.appeal(m, ts);
        vm.stopPrank();
        _fulfill(_requestIdFromLogs(vm.getRecordedLogs()), 99);
        (os, bs) = _uniform(7, WORKER_WINS, 10_000);
        os[6] = POSTER_WINS;
        bs[6] = 0; // one minority vote
        address[] memory r2 = _juryVotes(m, ts, os, bs);
        vm.prank(keeper);
        cage.closeRound(m, ts);
        BotledCageV5.Case memory c = cage.getCase(m, ts);
        vm.warp(c.deadline + 1);
        uint256 workerBefore = azl.balanceOf(worker);
        vm.prank(keeper);
        cage.finalize(m, ts);
        (,,,,,,,, uint8 outcome,) = IAzzleArbitrationV2(address(standard)).disputes(ts);
        assertEq(outcome, WORKER_WINS, "appeal reversed the round-1 result");
        // (on Base the same tx also pays the worker's escrow share, so only a lower bound is exact here)
        assertGe(azl.balanceOf(worker) - workerBefore, bond, "successful appellant gets the bond back");
        assertEq(cage.heldBonds(), 0, "no appeal bond left in the cage");
        // slashes: round-1 poster voters (now minority vs final) and the round-2 minority voter
        (,,, uint256 b0) = pool.runners(r1[0]);
        assertLt(b0, 1_000e18, "round-1 minority slashed");
        (,,, uint256 b6) = pool.runners(r2[6]);
        assertLt(b6, 1_000e18, "round-2 minority slashed");
        (,,, uint256 b2) = pool.runners(r2[0]);
        assertGt(b2, 1_000e18, "coherent juror rewarded");
    }
}

/// @notice Unit tests: real ArbitrationModuleV2 + VerifierBondVaultV2 + BotledPanelOwner; mocked registry/escrow/rep.
contract BotledV5UnitTest is V5Flows {
    AZL token;
    MockRegistry reg;
    MockVrfWrapper vrf;
    address safe = makeAddr("safe");
    uint256 nextTask;

    function _fund(address to, uint256 amount) internal override { token.mint(to, amount); }

    function _beforeExit() internal override {
        address other = makeAddr("other-seat");
        _fund(other, 11_000e18);
        vm.startPrank(other);
        azl.approve(address(mv), 1_000e18);
        azl.approve(address(sv), 10_000e18);
        mv.bond(1_000e18);
        sv.bond(10_000e18);
        vm.stopPrank();
        vm.deal(other, 1 ether);
        vm.prank(other);
        po.join{value: PFAND}();
    }

    function _party(ArbitrationModuleV2, uint256) internal view override returns (address, address) {
        return (reg.poster(), reg.worker());
    }

    function _dispute(ArbitrationModuleV2 m) internal override returns (uint256 id) {
        id = 1; // same task id on both modules on purpose (separate registries on Base)
        (,,,,,,, uint8 st,,) = IAzzleArbitrationV2(address(m)).disputes(id);
        while (st != 0) { ++id; (,,,,,,, st,,) = IAzzleArbitrationV2(address(m)).disputes(id); }
        reg.open(m, id, keccak256(abi.encode("ev", id)));
    }

    function _params() internal pure returns (BotledConfig.Params memory p) {
        p.jurySizes = [uint8(3), 7, 15];
        p.minProviders = 2;
        p.vrfTimeout = 1 hours;
        p.commitWindow = 3 hours;
        p.revealWindow = 2 hours;
        p.appealWindow = 6 hours;
        p.safetyMargin = 2 hours;
        p.appealBonds = [uint128(200e18), uint128(400e18)];
        p.noShowSlash = 50e18;
        p.minoritySlash = 20e18;
        p.rewardPerRound = 0;
    }

    function setUp() public {
        token = new AZL();
        azl = IERC20(address(token));
        MockTreasury tr = new MockTreasury();
        MockEscrow es = new MockEscrow();
        MockRep rep = new MockRep();
        reg = new MockRegistry();
        vrf = new MockVrfWrapper();
        mv = new VerifierBondVaultV2(address(token), 1_000e18, 7 days, address(tr), safe);
        sv = new VerifierBondVaultV2(address(token), 10_000e18, 7 days, address(tr), safe);
        micro = new ArbitrationModuleV2(address(reg), address(es), address(rep), address(mv), address(tr), 3 days, 2 days, 1000, new address[](0), safe);
        standard = new ArbitrationModuleV2(address(reg), address(es), address(rep), address(sv), address(tr), 3 days, 2 days, 1000, new address[](0), safe);
        vm.startPrank(safe);
        mv.configureArbitration(address(micro));
        sv.configureArbitration(address(standard));
        vm.stopPrank();
        po = new BotledPanelOwner(safe, IPanelModule(address(micro)), IPanelModule(address(standard)), PFAND, 128, address(0));
        vm.startPrank(safe);
        micro.transferOwnership(address(po));
        standard.transferOwnership(address(po));
        vm.stopPrank();
        po.acceptModuleOwnership();

        BotledConfig.Lane[] memory l = new BotledConfig.Lane[](2);
        l[0] = BotledConfig.Lane(bytes32("claude-opus-5"), bytes32("anthropic"));
        l[1] = BotledConfig.Lane(bytes32("gemini-4-argon"), bytes32("google"));
        BotledConfig.Constitution memory c;
        c.promptTemplateHash = keccak256("p");
        c.rubricHash = keccak256("r");
        c.schemaHash = keccak256("s");
        c.decodingHash = keccak256("d");
        address[] memory arbs = new address[](2);
        (arbs[0], arbs[1]) = (address(micro), address(standard));
        config = new BotledConfig(address(this), 1 days, _params(), c, l, arbs);
        _deployV5(address(config), address(vrf), address(po));
        _addRunners(12);
    }

    // ---------------------------------------------------------------- shared flows
    function testMicroAndStandardDisputesSameTaskId() public { _flowMicroAndStandard(); }
    function testAppealOnStandardWithSlashing() public { _flowAppealOnStandard(); }

    // ---------------------------------------------------------------- deploy / trust

    function testFactoryRejectsUnanchoredPool() public {
        BotledRunnerPool p2 = new BotledRunnerPool(address(config), address(azl), address(vrf), 100e18, 7 days, 100_000, 70_000, 3);
        vm.expectRevert(BotledFactoryV5.Anchor.selector);
        new BotledFactoryV5(config, address(p2), address(po), address(0), address(0));
    }

    function testOnlyV5CagesUsePool() public {
        vm.expectRevert(BotledRunnerPool.NotCage.selector);
        pool.requestDraw(1, address(1), address(2), 3, uint64(block.timestamp + 1 hours));
        uint256[] memory s = new uint256[](0);
        bool[] memory r = new bool[](0);
        vm.expectRevert(BotledRunnerPool.NotCage.selector);
        pool.settleDraw(1, s, r, 0);
    }

    function testFactoryRequiresBothModulesSupported() public {
        BotledConfig.Lane[] memory l = new BotledConfig.Lane[](2);
        l[0] = BotledConfig.Lane(bytes32("a"), bytes32("x"));
        l[1] = BotledConfig.Lane(bytes32("b"), bytes32("y"));
        BotledConfig.Constitution memory c;
        (c.promptTemplateHash, c.rubricHash, c.schemaHash) = (keccak256("p"), keccak256("r"), keccak256("s"));
        address[] memory arbs = new address[](1);
        arbs[0] = address(micro); // standard missing (= today's deployed config)
        BotledConfig c2 = new BotledConfig(address(this), 1 days, _params(), c, l, arbs);
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        BotledRunnerPool p2 = new BotledRunnerPool(predicted, address(azl), address(vrf), 100e18, 7 days, 100_000, 70_000, 3);
        BotledFactoryV5 f2 = new BotledFactoryV5(c2, address(p2), address(po), address(0), address(0));
        vm.expectRevert(BotledFactoryV5.Unsupported.selector);
        f2.deployCage(0, "x");
        c2.proposeArbitration(address(standard)); // 1-day timelock
        vm.warp(block.timestamp + 1 days);
        f2.deployCage(0, "x");
    }

    function testImplementationLockedAndInitOnce() public {
        BotledCageV5 impl = BotledCageV5(payable(factory.implementation()));
        vm.expectRevert(BotledCageV5.Init.selector);
        impl.initialize(0, address(this));
        _createAndSeat();
        vm.prank(address(factory));
        vm.expectRevert(BotledCageV5.Init.selector);
        cage.initialize(0, address(this));
        assertEq(factory.predictCage(operator, "op-1"), address(cage));
    }

    // ---------------------------------------------------------------- seat management

    function testSeatFunctionsOnlyOperator() public {
        _createAndSeat();
        vm.startPrank(keeper);
        vm.expectRevert(BotledCageV5.Auth.selector);
        cage.unseat();
        vm.expectRevert(BotledCageV5.Auth.selector);
        cage.scheduleExit();
        vm.expectRevert(BotledCageV5.Auth.selector);
        cage.withdrawBond(0, 0);
        vm.expectRevert(BotledCageV5.Auth.selector);
        cage.topUpBond(0, 2_000e18);
        vm.expectRevert(BotledCageV5.Auth.selector);
        cage.seat(0, 0);
        vm.expectRevert(BotledCageV5.Auth.selector);
        cage.exit();
        vm.stopPrank();
    }

    function testScheduleExitWhileSeatedRefused() public {
        _createAndSeat();
        vm.prank(operator);
        vm.expectRevert(BotledCageV5.StillSeated.selector);
        cage.scheduleExit();
    }

    function testWrongPfandRejected() public {
        vm.prank(operator);
        cage = BotledCageV5(payable(factory.deployCage(0, "x")));
        _fund(operator, 11_000e18);
        vm.deal(operator, 1 ether);
        vm.startPrank(operator);
        azl.approve(address(cage), 11_000e18);
        vm.expectRevert(BotledPanelOwner.BadPfand.selector);
        cage.seat{value: 0.001 ether}(0, 0);
        vm.stopPrank();
    }

    function testTopUpAddsCapacityForParallelDisputes() public {
        _createAndSeat();
        _fund(operator, 1_000e18);
        vm.startPrank(operator);
        azl.approve(address(cage), 1_000e18);
        cage.topUpBond(0, 2_000e18);
        vm.stopPrank();
        uint256 a = _dispute(micro);
        uint256 b = _dispute(micro);
        (,, address x,,,,,,,) = micro.disputes(a);
        (,, address y,,,,,,,) = micro.disputes(b);
        assertEq(x, address(cage));
        assertEq(y, address(cage));
        assertFalse(mv.isEligible(address(cage)), "capacity used up");
    }

    function testLastEligibleMemberCannotLeave() public {
        _createAndSeat();
        vm.prank(operator);
        vm.expectRevert(bytes("AMv2: final eligible member"));
        cage.unseat();
    }

    function testReseatAfterExitCancelsWithdrawal() public {
        _createAndSeat();
        _beforeExit();
        vm.prank(operator);
        cage.exit();
        assertFalse(mv.isEligible(address(cage)));
        _fund(operator, 2);
        vm.startPrank(operator);
        azl.approve(address(cage), 2);
        cage.seat{value: PFAND}(0, 0); // +1 wei per vault resets the cooldown
        vm.stopPrank();
        assertTrue(po.isSeated(address(cage)) && mv.isEligible(address(cage)) && sv.isEligible(address(cage)));
    }

    function testKickedWhenBondWithdrawnElsewhereIsImpossible() public {
        _createAndSeat();
        // the vault only credits/debits the cage itself; nobody but the operator path can unbond
        assertFalse(po.kickable(address(cage)));
    }

    // ---------------------------------------------------------------- case isolation / security

    function testFakeModuleRejected() public {
        _createAndSeat();
        vm.expectRevert(BotledCageV5.Module.selector);
        cage.openCase(address(0xBAD), 1);
        vm.expectRevert(BotledCageV5.Module.selector);
        cage.drawId(address(0xBAD), 1, 1);
    }

    function testDrawIdRoundTrip() public {
        _createAndSeat();
        uint256 id = cage.drawId(address(standard), 77, 2);
        (address a, uint256 t, uint8 r) = cage.decodeDrawId(id);
        assertEq(a, address(standard));
        assertEq(t, 77);
        assertEq(r, 2);
        assertTrue(cage.drawId(address(micro), 77, 2) != id, "modules never share a draw");
    }

    function testRunnerCannotCommitAcrossModules() public {
        _createAndSeat();
        uint256 tm = _dispute(micro);
        uint256 ts = _dispute(standard);
        assertEq(tm, ts, "same task id");
        _open(address(micro), tm, 5);
        address[] memory list = pool.drawnRunners(address(cage), cage.drawId(address(micro), tm, 1));
        // standard case not opened: commit there is impossible
        vm.prank(list[0]);
        vm.expectRevert(BotledCageV5.Phase_.selector);
        cage.commit(address(standard), ts, bytes32(uint256(1)));
        _open(address(standard), ts, 6);
        // a runner drawn only for micro cannot commit for standard
        address[] memory sl = pool.drawnRunners(address(cage), cage.drawId(address(standard), ts, 1));
        address outsider;
        for (uint256 i; i < list.length && outsider == address(0); ++i) {
            bool inS;
            for (uint256 j; j < sl.length; ++j) if (sl[j] == list[i]) inS = true;
            if (!inS) outsider = list[i];
        }
        if (outsider != address(0)) {
            vm.prank(outsider);
            vm.expectRevert(BotledCageV5.Auth.selector);
            cage.commit(address(standard), ts, bytes32(uint256(1)));
        }
        // and a micro commitment does not reveal on standard (commitment binds the module)
        bytes32 h = _commitment(address(micro), tm, 1, list[0], 1, 0, 0, bytes32(uint256(9)));
        vm.prank(list[0]);
        cage.commit(address(micro), tm, h);
        assertTrue(cage.commitmentOf(address(standard), ts, 1, list[0]) == 0);
    }

    function testNoShowSlashedAndTimeoutSync() public {
        _createAndSeat();
        uint256 tm = _dispute(micro);
        address m = address(micro);
        _open(m, tm, 3);
        // nobody commits; rounds auto-escalate while they fit, then Azzle timeout + sync
        for (uint256 i; i < 3; ++i) {
            BotledCageV5.Case memory c = cage.getCase(m, tm);
            if (c.phase != BotledCageV5.Phase.JURY) break;
            (, uint256 revealEnd) = cage.windows(m, tm);
            vm.warp((revealEnd == 0 ? c.deadline : revealEnd) + 1);
            vm.recordLogs();
            cage.closeRound(m, tm);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            bytes32 sig = keccak256("DrawRequested(address,uint256,uint256,uint256)");
            for (uint256 j; j < logs.length; ++j) {
                if (logs[j].emitter == address(pool) && logs[j].topics[0] == sig) {
                    (uint256 rid,) = abi.decode(logs[j].data, (uint256, uint256));
                    _fulfill(rid, 1000 + j);
                }
            }
        }
        (,,,,, uint64 evd, uint64 rd,,,) = micro.disputes(tm);
        vm.warp((rd == 0 ? evd + 2 days : rd) + 1);
        micro.timeout(tm);
        cage.syncAzzleTimeout(m, tm);
        assertEq(uint8(cage.getCase(m, tm).phase), 3);
        uint256 slashedRunners;
        for (uint256 i; i < runners.length; ++i) {
            (, uint32 active,, uint256 bond) = pool.runners(runners[i]);
            assertEq(active, 0, "released");
            if (bond < 1_000e18) ++slashedRunners;
        }
        assertGt(slashedRunners, 0, "no-shows slashed");
    }

    /// @dev Fixed vectors shared with runner-node/botled-runner-node.ts (`--vectors`).
    function testV5HashVectors() public pure {
        bytes32 commitment = keccak256(
            abi.encode(
                address(1), address(3), uint256(7), uint8(1), address(2), bytes32(uint256(0x11)), uint8(2), uint16(10_000),
                uint8(1), bytes32(uint256(0x22)), bytes32(uint256(0x33))
            )
        );
        assertEq(commitment, 0xa2664815f80492dc2c58086ee152ddd5450061d8c9d9046ece6f1a2ca4e40f92, "v5 commitment vector");
    }
}

interface IFRegistry {
    function deposits() external view returns (address);
    function escrow() external view returns (address);
    function usdOracle() external view returns (address);
    function post(uint256 totalAmount, uint64 deadline) external returns (uint256);
    function claim(uint256 taskId) external;
    function fund(uint256 taskId, uint256 amount) external;
    function markDelivered(uint256 taskId) external;
    function openDispute(uint256 taskId, bytes32 evidenceHash) external;
    function taskParties(uint256 taskId) external view returns (address, address);
}

interface IFDeposits { function gateway() external view returns (address); }

interface IFGateway { function fundWithEth(uint256 minAzlOut, uint256 deadline) external payable returns (uint256); }

interface IFOracle {
    function isValid() external view returns (bool);
    function record() external;
}

/// @notice Fork tests against the LIVE Base contracts: deployed BotledConfig, BotledPanelOwner, both Azzle modules
///         and vaults, the Chainlink VRF wrapper and real Azzle tasks (deposits via AzlPaymentGateway, escrow,
///         registry). Nothing is broadcast. Run: FORK_BASE=true BASE_RPC=<url> forge test --match-contract BotledV5Fork
contract BotledV5ForkTest is V5Flows {
    using stdStorage for StdStorage;
    address constant CONFIG = 0x6A5785cc5e79Dc4c800367b54eA525c5e31040D7;
    address constant PANEL_OWNER = 0xF7E5A611154C8d30A03791409F2606C278597a04;
    address constant MICRO = 0x905E561B44E76fdeAF5F41Bc2c46ebCE4E5E02fE;
    address constant STANDARD = 0x1003592A2eeF71b15A21457910007b38B0e2027A;
    address constant AZL_TOKEN = 0x931517E9502F9d52CDF6F5AC7fca7925e2A1BBA3;
    address constant VRF_WRAPPER = 0xb0407dbe851f8318bd31404A49e658143C982F23;
    address constant DEPLOYER = 0x3D5eb1F648F495fAEFaeBa0dE74A5c52b6602F5D; // config owner + AZL holder
    address constant OBS_ORACLE = 0xA6EbECbe792c00D0b42a16B790Ab9fE356654C0A;
    address constant V4_CAGE = 0xe16bF0267C36dA27a037F8340BdE2909B117EFb2;
    bool on;
    address poster = makeAddr("fork-poster");
    address worker = makeAddr("fork-worker");

    function _fund(address to, uint256 amount) internal override {
        vm.prank(DEPLOYER);
        azl.transfer(to, amount);
    }

    function _party(ArbitrationModuleV2 m, uint256 taskId) internal view override returns (address, address) {
        return IFRegistry(address(m.registry())).taskParties(taskId);
    }

    function setUp() public {
        on = vm.envOr("FORK_BASE", false);
        if (!on) return;
        vm.createSelectFork(vm.envOr("BASE_RPC", string("https://mainnet.base.org")));
        azl = IERC20(AZL_TOKEN);
        config = BotledConfig(CONFIG);
        po = BotledPanelOwner(payable(PANEL_OWNER));
        micro = ArbitrationModuleV2(MICRO);
        standard = ArbitrationModuleV2(STANDARD);
        mv = VerifierBondVaultV2(address(micro.bonds()));
        sv = VerifierBondVaultV2(address(standard.bonds()));
        assertEq(micro.owner(), PANEL_OWNER);
        assertEq(standard.owner(), PANEL_OWNER);
        // the one config change v5 needs: standard module support (owner call + 1-day timelock)
        if (!config.isSupportedArbitration(STANDARD)) {
            vm.prank(config.owner());
            config.proposeArbitration(STANDARD);
            // Time-travelling 1 day would stale Azzle's Chainlink ETH/USD feed (deposits need it), so the elapsed
            // timelock is simulated by moving activeAt to now. The timelock itself is covered by the unit tests.
            stdstore.target(CONFIG).sig("arbitrationActiveAt(address)").with_key(STANDARD).checked_write(block.timestamp);
            assertTrue(config.isSupportedArbitration(STANDARD));
        }
        uint256 g = gasleft();
        _deployV5(CONFIG, VRF_WRAPPER, PANEL_OWNER);
        emit log_named_uint("v5 pool + factory(+impl) deploy gas (excl. intrinsic)", g - gasleft());
        _addRunners(12);
    }

    function _oracle(address reg) internal {
        IFOracle o = IFOracle(IFRegistry(reg).usdOracle());
        if (!o.isValid()) IFOracle(OBS_ORACLE).record();
    }

    /// @dev Old members step aside exactly like on mainnet (withdrawal scheduled => skipped by round-robin).
    function _routeToCage(ArbitrationModuleV2 m) internal {
        VerifierBondVaultV2 v = VerifierBondVaultV2(address(m.bonds()));
        uint256 len = m.panelLength();
        for (uint256 i; i < len; ++i) {
            address a = m.panelMember(i);
            if (a == address(0) || a == address(cage) || !v.isEligible(a)) continue;
            vm.prank(a);
            v.scheduleWithdrawal();
        }
    }

    function _beforeExit() internal override {
        address[2] memory vs = [address(mv), address(sv)];
        for (uint256 k; k < 2; ++k) {
            ArbitrationModuleV2 m = k == 0 ? micro : standard;
            VerifierBondVaultV2 v = VerifierBondVaultV2(vs[k]);
            uint256 len = m.panelLength();
            for (uint256 i; i < len; ++i) {
                address a = m.panelMember(i);
                if (a == address(0) || a == address(cage) || v.withdrawReadyAt(a) == 0) continue;
                _fund(a, 1);
                vm.startPrank(a);
                azl.approve(address(v), 1);
                v.bond(1); // cancels the scheduled withdrawal (same as the live E2E clean-up)
                vm.stopPrank();
            }
        }
    }

    function _dispute(ArbitrationModuleV2 m) internal override returns (uint256 taskId) {
        _routeToCage(m);
        IFRegistry reg = IFRegistry(address(m.registry()));
        IFGateway gw = IFGateway(IFDeposits(reg.deposits()).gateway());
        _oracle(address(reg));
        vm.deal(poster, 10 ether);
        vm.deal(worker, 10 ether);
        // deposits: micro quote ~17M AZL per party, standard ~146M AZL per party (entry + reserve + access fee)
        // (the gateway caps one swap's input, so the standard deposit is split into several calls)
        uint256 n = address(m) == MICRO ? 1 : 6;
        for (uint256 i; i < n; ++i) {
            vm.prank(poster);
            gw.fundWithEth{value: 0.02 ether}(1, block.timestamp + 300);
            vm.prank(worker);
            gw.fundWithEth{value: 0.02 ether}(1, block.timestamp + 300);
        }
        uint256 bounty = 1_000_000e18;
        _fund(poster, bounty);
        _oracle(address(reg));
        vm.prank(poster);
        taskId = reg.post(bounty, uint64(block.timestamp + 7 days));
        vm.prank(worker);
        reg.claim(taskId);
        vm.startPrank(poster);
        azl.approve(reg.escrow(), bounty);
        reg.fund(taskId, bounty);
        vm.stopPrank();
        vm.prank(worker);
        reg.markDelivered(taskId);
        vm.prank(poster);
        reg.openDispute(taskId, keccak256(abi.encode("poster evidence", address(m), taskId)));
        vm.prank(worker);
        m.submitEvidence(taskId, keccak256(abi.encode("worker evidence", address(m), taskId)));
        (,, address arb,,,,,,,) = IAzzleArbitrationV2(address(m)).disputes(taskId);
        assertEq(arb, address(cage), "real dispute assigned to the v5 cage");
    }

    function testForkCreateJoinBothRuleBothLeave() public { if (on) _flowMicroAndStandard(); }
    function testForkAppealOnStandard() public { if (on) _flowAppealOnStandard(); }

    function testForkGasProfile() public {
        if (!on) return;
        uint256 g = gasleft();
        vm.prank(operator);
        cage = BotledCageV5(payable(factory.deployCage(0, "gas")));
        emit log_named_uint("deployCage gas", g - gasleft());
        _fund(operator, 11_000e18);
        vm.deal(operator, 1 ether);
        vm.startPrank(operator);
        azl.approve(address(cage), 11_000e18);
        g = gasleft();
        cage.seat{value: PFAND}(0, 0);
        emit log_named_uint("seat (bond both vaults + join) gas", g - gasleft());
        vm.stopPrank();
        assertTrue(po.isSeated(address(cage)));
        assertFalse(po.isSeated(V4_CAGE), "v4 cage untouched");
    }
}
