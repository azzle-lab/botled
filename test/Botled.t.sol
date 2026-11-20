// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ArbitrationModuleV2} from "azzle-v2/ArbitrationModuleV2.sol";
import {VerifierBondVaultV2} from "azzle-v2/VerifierBondVaultV2.sol";
import {PanelJoinGate} from "../src/azzle-deployed/PanelJoinGate.sol";
import {PanelJoinGateV2} from "../src/azzle-optional/PanelJoinGateV2.sol";
import {BotledConfig} from "../src/botled/BotledConfig.sol";
import {BotledRunnerPool} from "../src/botled/BotledRunnerPool.sol";
import {BotledFactory} from "../src/botled/BotledFactory.sol";
import {BotledArbitrator} from "../src/botled/BotledArbitrator.sol";
import {IAzzlePanelGate} from "../src/botled/interfaces/IAzzle.sol";
import {NativeVrfConsumer} from "../src/shared/NativeVrfConsumer.sol";

contract AZL is ERC20 {
    constructor() ERC20("AZL", "AZL") {}
    function mint(address a, uint256 v) external { _mint(a, v); }
}

/// @dev Any ERC20 can be the Botled bond token (runner + appeal bonds), e.g. for a cheap mainnet E2E test.
contract TestBondToken is ERC20 {
    constructor() ERC20("Botled Test Bond", "tBOND") {}
    function mint(address a, uint256 v) external { _mint(a, v); }
}

/// @dev Mock of the ArbitrationModuleV2 surface a cage uses (disputes / beginRuling / rule / registry / bonds /
///      rulingWindow). Records the exact `rule` call. Outcome is uint8 in the ABI, same as the real module.
contract MockArbitrationModule {
    struct D { address arbitrator; bytes32 pe; bytes32 we; uint64 evDeadline; uint64 rulingDeadline; uint8 status; uint8 outcome; }
    mapping(uint256 => D) public d;
    address public bonds;
    uint64 public rulingWindow = 172800;
    address public poster = address(0xA11CE);
    address public worker = address(0xB0B);
    uint256 public ruleCalls;
    uint256 public lastTask;
    uint8 public lastOutcome;
    uint16 public lastBps;
    address public lastCaller;
    constructor(address vault_) { bonds = vault_; }
    function registry() external view returns (address) { return address(this); }
    function taskParties(uint256) external view returns (address, address) { return (poster, worker); }
    function open(uint256 id, address arb) external {
        d[id] = D(arb, keccak256("pe"), keccak256("we"), uint64(block.timestamp + 259200), 0, 1, 0);
    }
    function disputes(uint256 id) external view returns (uint256, address, address, bytes32, bytes32, uint64, uint64, uint8, uint8, uint256) {
        D memory x = d[id];
        return (id, poster, x.arbitrator, x.pe, x.we, x.evDeadline, x.rulingDeadline, x.status, x.outcome, 0);
    }
    function beginRuling(uint256 id) external {
        require(d[id].status == 1 && block.timestamp > d[id].evDeadline, "phase");
        d[id].status = 2;
        d[id].rulingDeadline = d[id].evDeadline + rulingWindow;
    }
    function rule(uint256 id, uint8 o, uint16 b) external {
        require(msg.sender == d[id].arbitrator && d[id].status == 2 && block.timestamp <= d[id].rulingDeadline, "AMv2: arbitrator");
        d[id].status = 3;
        d[id].outcome = o;
        ruleCalls++;
        (lastTask, lastOutcome, lastBps, lastCaller) = (id, o, b, msg.sender);
    }
}

contract MockVault { address public azl; constructor(address a) { azl = a; } }

contract MockTreasury { function recordBondSlashRevenue(uint256) external {} }

contract MockEscrow {
    uint16 public lastBps;
    function freeze(uint256) external {}
    function canSettle(uint256) external pure returns (bool) { return true; }
    function settle(uint256, uint16 b) external { lastBps = b; }
}

contract MockRep {
    function canRecordDispute(uint256, address, address, bool) external pure returns (bool) { return true; }
    function recordDispute(uint256, address, address, bool) external {}
    function recordUnresolvedDispute(uint256, address) external {}
}

contract MockRegistry {
    address public poster = address(0xA11CE);
    address public worker = address(0xB0B);
    uint256 public taskCount;
    function taskParties(uint256) external view returns (address, address) { return (poster, worker); }
    function taskTimelyDelivered(uint256) external pure returns (bool) { return true; }
    function canResolveDispute(uint256, uint8) external pure returns (bool) { return true; }
    function resolveDispute(uint256, uint8) external {}
    function open(ArbitrationModuleV2 m, uint256 id, bytes32 ev) external {
        if (id > taskCount) taskCount = id;
        m.openDispute(id, poster, ev);
    }
}

/// @dev Minimal Safe stand-in: owner calls + module calls.
contract MockSafe {
    mapping(address => bool) public modules;
    function enableModule(address m) external { modules[m] = true; }
    function call(address to, bytes calldata data) external returns (bytes memory r) {
        bool ok;
        (ok, r) = to.call(data);
        require(ok, "safe call");
    }
    function execTransactionFromModule(address to, uint256 value, bytes calldata data, uint8) external returns (bool ok) {
        require(modules[msg.sender], "GS104");
        (ok,) = to.call{value: value}(data);
    }
}

contract MockVrfWrapper {
    uint256 public price = 0.0001 ether;
    uint256 public lastId;
    uint32 public lastGasLimit;
    mapping(uint256 => uint32) public gasOf;
    uint256 public lastFulfillGas;
    mapping(uint256 => address) public consumerOf;
    function setPrice(uint256 p) external { price = p; }
    function calculateRequestPriceNative(uint32, uint32) external view returns (uint256) { return price; }
    function requestRandomWordsInNative(uint32 gasLimit, uint16, uint32 n, bytes calldata extra) external payable returns (uint256) {
        lastGasLimit = gasLimit;
        require(msg.value >= price && n == 1, "price");
        require(bytes4(extra[:4]) == bytes4(keccak256("VRF ExtraArgsV1")) && abi.decode(extra[4:], (bool)), "native");
        consumerOf[++lastId] = msg.sender;
        gasOf[lastId] = gasLimit;
        return lastId;
    }
    function fulfill(uint256 id, uint256 word) external {
        uint256[] memory w = new uint256[](1);
        w[0] = word;
        uint256 g = gasleft();
        NativeVrfConsumer(consumerOf[id]).rawFulfillRandomWords{gas: gasOf[id]}(id, w);
        lastFulfillGas = g - gasleft();
    }
}

/// @dev A non-factory contract that bonds and tries to join / draw runners.
contract FakeCage {
    function bondAndJoin(VerifierBondVaultV2 v, AZL azl, PanelJoinGateV2 g, address arb, uint256 amt) external payable {
        azl.approve(address(v), amt);
        v.bond(amt);
        g.joinPanel{value: msg.value}(arb);
    }
    function draw(BotledRunnerPool p) external { p.requestDraw(1, address(1), address(2), 3, uint64(block.timestamp + 1 hours)); }
}


contract BotledTest is Test {
    AZL azl;
    MockRegistry reg;
    MockEscrow esc;
    MockSafe safe;
    MockVrfWrapper vrf;
    VerifierBondVaultV2 vault;
    VerifierBondVaultV2 vault2;
    ArbitrationModuleV2 module;
    ArbitrationModuleV2 module2;
    MockArbitrationModule mockModule;
    BotledConfig config;
    BotledRunnerPool pool;
    BotledFactory factory;
    PanelJoinGateV2 gate;

    address human = address(0x4D11);
    address[] runners;
    uint256 constant N_RUNNERS = 20;
    uint256 constant MIN = 1000e18;
    uint256 constant PFAND = 0.001 ether;
    uint32 constant CID = 0;
    uint64 constant EVIDENCE = 259200;
    uint64 constant RULING = 172800;

    // production-like params (3 / 7 / 15)
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
        p.rewardPerRound = 30e18;
    }

    function _constitution() internal pure returns (BotledConfig.Constitution memory c) {
        c.promptTemplateHash = keccak256("botled-prompt-v1");
        c.rubricHash = keccak256("botled-rubric-v1");
        c.schemaHash = keccak256("botled_ruling.schema.v1");
        c.decodingHash = keccak256("temperature=0,seed=0,max_tokens=800");
    }

    function _lanes() internal pure returns (BotledConfig.Lane[] memory l) {
        l = new BotledConfig.Lane[](2);
        l[0] = BotledConfig.Lane(bytes32("claude-opus-5"), bytes32("anthropic"));
        l[1] = BotledConfig.Lane(bytes32("gemini-4-argon"), bytes32("google"));
    }

    function setUp() public {
        azl = new AZL();
        MockTreasury t = new MockTreasury();
        esc = new MockEscrow();
        reg = new MockRegistry();
        safe = new MockSafe();
        vrf = new MockVrfWrapper();
        MockRep rep = new MockRep();
        vault = new VerifierBondVaultV2(address(azl), MIN, 7 days, address(t), address(this));
        vault2 = new VerifierBondVaultV2(address(azl), MIN, 7 days, address(t), address(this));
        module = new ArbitrationModuleV2(address(reg), address(esc), address(rep), address(vault), address(t), EVIDENCE, RULING, 1000, new address[](0), address(safe));
        module2 = new ArbitrationModuleV2(address(reg), address(esc), address(rep), address(vault2), address(t), EVIDENCE, RULING, 1000, new address[](0), address(safe));
        vault.configureArbitration(address(module));
        vault2.configureArbitration(address(module2));
        mockModule = new MockArbitrationModule(address(new MockVault(address(azl))));

        address[] memory arbs = new address[](3);
        (arbs[0], arbs[1], arbs[2]) = (address(module), address(module2), address(mockModule));
        config = new BotledConfig(address(this), 1 days, _params(), _constitution(), _lanes(), arbs);
        pool = new BotledRunnerPool(address(config), address(azl), address(vrf), 100e18, 7 days, 100_000, 60_000, 3);
        factory = new BotledFactory(config, address(pool), address(0));
        config.wire(address(factory), address(pool));

        gate = new PanelJoinGateV2(
            address(safe), address(module), address(module2), address(factory), address(pool), address(vrf),
            PFAND, MIN, [uint64(1 days), uint64(2 days), uint64(1 days), uint64(90 days)], 3, 200_000
        );
        safe.enableModule(address(gate));

        for (uint256 i; i < N_RUNNERS; ++i) {
            runners.push(vm.addr(0x1000 + i));
            _addRunner(runners[i]);
        }
        vm.deal(address(pool), 1 ether);
        azl.mint(address(this), 10_000e18);
        azl.approve(address(pool), 10_000e18);
        pool.fundRewards(10_000e18);
    }

    // ------------------------------------------------------------ helpers

    function _addRunner(address r) internal {
        azl.mint(r, 1000e18);
        vm.startPrank(r);
        azl.approve(address(pool), type(uint256).max);
        pool.registerRunner(500e18);
        vm.stopPrank();
    }

    function _deployCage(address op, bytes32 salt) internal returns (BotledArbitrator cage) {
        return _deployCageFor(op, salt, address(module));
    }

    function _deployCageFor(address op, bytes32 salt, address arb) internal returns (BotledArbitrator cage) {
        vm.prank(op);
        cage = BotledArbitrator(payable(factory.deployCage(arb, CID, salt)));
        azl.mint(op, 20_000e18);
        vm.prank(op);
        azl.approve(address(cage), type(uint256).max);
        vm.deal(op, 1 ether);
    }

    function _requestJoin(BotledArbitrator cage, address op) internal returns (uint256 id) {
        uint256 cost = gate.joinCost(address(cage));
        vm.prank(op);
        cage.joinPanel{value: cost}(IAzzlePanelGate(address(gate)));
        id = vrf.lastId();
    }

    function _joinFully(BotledArbitrator cage, address op, uint256 word) internal {
        uint256 id = _requestJoin(cage, op);
        vrf.fulfill(id, word);
        (, uint64 readyAt,) = gate.joins(address(cage), address(module));
        vm.warp(readyAt);
        gate.activate(address(cage), address(module));
    }

    function _seat(bytes32 salt) internal returns (BotledArbitrator cage) {
        address op = address(0x0F1);
        cage = _deployCage(op, salt);
        _joinFully(cage, op, 0);
    }

    function _inputHash(BotledArbitrator cage, uint256 taskId) internal view returns (bytes32 h) {
        (, , , , , , h, , ,) = cage.cases(taskId);
    }

    function _phase(BotledArbitrator cage, uint256 taskId) internal view returns (BotledArbitrator.Phase ph, uint8 round, uint64 deadline) {
        (ph, round, , , deadline, , , , ,) = cage.cases(taskId);
    }

    function _open(BotledArbitrator cage, uint256 taskId) internal {
        reg.open(module, taskId, keccak256("ev"));
        (, , address arb, , , , , , ,) = module.disputes(taskId);
        assertEq(arb, address(cage), "assigned to cage");
        vm.warp(block.timestamp + EVIDENCE + 1);
        cage.openCase(taskId);
    }

    function _salt(address r, uint8 round) internal pure returns (bytes32) { return keccak256(abi.encode(r, round)); }

    function _commitment(BotledArbitrator cage, uint256 taskId, uint8 round, address r, uint8 o, uint16 b, uint8 lane)
        internal
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(address(cage), taskId, round, r, _inputHash(cage, taskId), o, b, lane, keccak256("t"), _salt(r, round))
        );
    }

    function _commit(BotledArbitrator cage, uint256 taskId, uint8 round, address r, uint8 o, uint16 b, uint8 lane) internal {
        bytes32 h = _commitment(cage, taskId, round, r, o, b, lane);
        vm.prank(r);
        cage.commit(taskId, h);
    }

    function _reveal(BotledArbitrator cage, uint256 taskId, uint8 round, address r, uint8 o, uint16 b, uint8 lane) internal {
        vm.prank(r);
        cage.reveal(taskId, o, b, lane, keccak256("t"), _salt(r, round));
    }

    function _lane(uint256 i) internal pure returns (uint8) { return uint8(i % 2); }

    function _drawn(BotledArbitrator cage, uint256 taskId, uint8 round) internal view returns (address[] memory) {
        return pool.drawnRunners(address(cage), cage.drawId(taskId, round));
    }

    /// Fulfils the pending VRF draw and lets every drawn juror vote (o, b) on alternating lanes.
    function _juryRound(BotledArbitrator cage, uint256 taskId, uint8 round, uint8 o, uint16 b) internal returns (address[] memory d) {
        vrf.fulfill(vrf.lastId(), uint256(keccak256(abi.encode(taskId, round))));
        d = _drawn(cage, taskId, round);
        for (uint256 i; i < d.length; ++i) _commit(cage, taskId, round, d[i], o, b, _lane(i));
        (uint256 commitEnd,) = cage.windows(taskId);
        vm.warp(commitEnd + 1);
        for (uint256 i; i < d.length; ++i) _reveal(cage, taskId, round, d[i], o, b, _lane(i));
        cage.closeRound(taskId); // early close: everyone revealed
    }

    function _appeal(BotledArbitrator cage, uint256 taskId, address who) internal {
        azl.mint(who, 10_000e18);
        vm.startPrank(who);
        azl.approve(address(cage), type(uint256).max);
        cage.appeal(taskId);
        vm.stopPrank();
    }

    function _outcome(uint256 taskId) internal view returns (uint8 st, uint8 o) {
        (, , , , , , , ArbitrationModuleV2.Status s, ArbitrationModuleV2.Outcome oc,) = module.disputes(taskId);
        return (uint8(s), uint8(oc));
    }

    function _bond(address r) internal view returns (uint256 b) { (,,, b) = pool.runners(r); }

    function _active(address r) internal view returns (uint32 a) { (, a,,) = pool.runners(r); }

    // ================================================================ VRF draw

    function testVrfDrawPicksDistinctEligibleRunners() public {
        BotledArbitrator cage = _seat("a");
        _open(cage, 1);
        (uint64 requestedAt, uint64 fulfilledAt, uint256 count,) = pool.drawInfo(address(cage), cage.drawId(1, 1));
        assertGt(requestedAt, 0, "draw requested in openCase");
        assertEq(fulfilledAt, 0);
        assertEq(count, 0);
        assertEq(vrf.gasOf(vrf.lastId()), pool.callbackGas(3), "callback gas sized for 3 jurors");
        (BotledArbitrator.Phase ph, uint8 round,) = _phase(cage, 1);
        assertEq(uint8(ph), uint8(BotledArbitrator.Phase.JURY));
        assertEq(round, 1);

        // nobody can commit before the draw, nobody but the wrapper can fulfil
        vm.prank(runners[0]);
        vm.expectRevert(BotledArbitrator.Phase_.selector);
        cage.commit(1, bytes32(uint256(1)));
        uint256 id = vrf.lastId();
        vm.expectRevert(NativeVrfConsumer.OnlyVrfWrapper.selector);
        pool.rawFulfillRandomWords(id, new uint256[](1));

        // a different random word draws a different jury
        uint256 snap = vm.snapshotState();
        vrf.fulfill(id, 4242);
        address[] memory alt = _drawn(cage, 1, 1);
        vm.revertToState(snap);

        vrf.fulfill(id, 42);
        address[] memory d = _drawn(cage, 1, 1);
        assertEq(d.length, 3);
        for (uint256 i; i < 3; ++i) {
            assertTrue(d[i] != reg.poster() && d[i] != reg.worker() && d[i] != address(cage));
            assertEq(_active(d[i]), 1, "reserve locked");
            for (uint256 j; j < i; ++j) assertTrue(d[i] != d[j], "distinct");
        }
        assertLt(vrf.lastFulfillGas(), pool.callbackGas(3), "fits callback gas");
        vrf.fulfill(id, 43); // second answer ignored
        assertEq(_drawn(cage, 1, 1).length, 3);
        assertEq(_drawn(cage, 1, 1)[0], d[0]);
        bool same = true;
        for (uint256 i; i < 3; ++i) if (alt[i] != d[i]) same = false;
        assertFalse(same, "jury depends on the VRF word");
    }

    function testLateVrfAnswerIsIgnored() public {
        BotledArbitrator cage = _seat("a");
        _open(cage, 3);
        uint256 id = vrf.lastId();
        vm.warp(block.timestamp + 1 hours + 1); // past vrfTimeout
        vrf.fulfill(id, 7);
        (, uint64 f, uint256 count,) = pool.drawInfo(address(cage), cage.drawId(3, 1));
        assertEq(f, 0);
        assertEq(count, 0, "nobody drawn for a closed round");
        cage.closeRound(3);
        (BotledArbitrator.Phase ph, uint8 round,) = _phase(cage, 3);
        assertEq(uint8(ph), uint8(BotledArbitrator.Phase.JURY));
        assertEq(round, 2, "no verdict -> automatic round 2, no bond");
        (,,,, uint128 b,) = cage.rounds(3, 2);
        assertEq(b, 0);
    }

    function testUnfundedVrfCanBeRetried() public {
        BotledArbitrator cage = _seat("a");
        vrf.setPrice(2 ether); // pool holds 1 ether
        _open(cage, 4);
        (uint64 requestedAt,,,) = pool.drawInfo(address(cage), cage.drawId(4, 1));
        assertEq(requestedAt, 0, "no draw without VRF funds");
        vm.expectRevert(BotledArbitrator.Phase_.selector);
        cage.retryDraw(4); // still unfunded
        cage.retryDraw{value: 1 ether}(4); // caller tops up the pool's VRF fund
        (requestedAt,,,) = pool.drawInfo(address(cage), cage.drawId(4, 1));
        assertGt(requestedAt, 0);
        vm.expectRevert(BotledArbitrator.Phase_.selector);
        cage.retryDraw(4);
        _juryRound(cage, 4, 1, 2, 10_000);
    }

    // ================================================================ commit / reveal / majority

    function testHappyPathMajorityRulesAndMinorityIsSlashed() public {
        BotledArbitrator cage = _seat("a");
        _open(cage, 5);
        vrf.fulfill(vrf.lastId(), 5);
        address[] memory d = _drawn(cage, 5, 1);
        _commit(cage, 5, 1, d[0], 2, 10_000, 0);
        _commit(cage, 5, 1, d[1], 2, 10_000, 1);
        _commit(cage, 5, 1, d[2], 1, 0, 0);
        (uint256 commitEnd,) = cage.windows(5);
        vm.warp(commitEnd + 1);
        _reveal(cage, 5, 1, d[0], 2, 10_000, 0);
        _reveal(cage, 5, 1, d[1], 2, 10_000, 1);
        _reveal(cage, 5, 1, d[2], 1, 0, 0);
        cage.closeRound(5);
        (BotledArbitrator.Phase ph,, uint64 dl) = _phase(cage, 5);
        assertEq(uint8(ph), uint8(BotledArbitrator.Phase.APPEAL));
        assertEq(dl, block.timestamp + 6 hours);
        vm.expectRevert(BotledArbitrator.Phase_.selector);
        cage.finalize(5);
        vm.warp(dl + 1);
        uint256 b0 = _bond(d[0]);
        uint256 b2 = _bond(d[2]);
        cage.finalize(5);
        (uint8 st, uint8 o) = _outcome(5);
        assertEq(st, 3, "SETTLED");
        assertEq(o, 2, "WORKER_WINS");
        assertEq(b2 - _bond(d[2]), 20e18, "minority slashed");
        assertEq(_bond(d[0]) - b0, (20e18 + 30e18) / 2, "majority gets the slash + rewardPerRound");
        for (uint256 i; i < 3; ++i) assertEq(_active(d[i]), 0, "reserves released");
    }

    function testCommitRevealRules() public {
        BotledArbitrator cage = _seat("a");
        _open(cage, 6);
        vrf.fulfill(vrf.lastId(), 6);
        address[] memory d = _drawn(cage, 6, 1);
        address outsider = address(0x0D0);
        vm.prank(outsider);
        vm.expectRevert(BotledArbitrator.Auth.selector);
        cage.commit(6, bytes32(uint256(1)));
        _commit(cage, 6, 1, d[0], 2, 10_000, 0);
        vm.prank(d[0]);
        vm.expectRevert(BotledArbitrator.Auth.selector);
        cage.commit(6, bytes32(uint256(2))); // no re-commit
        _commit(cage, 6, 1, d[1], 3, 6_000, 1);
        _commit(cage, 6, 1, d[2], 3, 6_100, 5); // off-grid bps, lane out of range
        // reveal only after the commit window
        vm.expectRevert(BotledArbitrator.Phase_.selector);
        _reveal(cage, 6, 1, d[0], 2, 10_000, 0);
        (uint256 commitEnd, uint256 revealEnd) = cage.windows(6);
        vm.warp(commitEnd + 1);
        vm.prank(d[1]);
        vm.expectRevert(BotledArbitrator.Phase_.selector);
        cage.commit(6, bytes32(uint256(3))); // window closed (late commit)
        // wrong vote / salt
        vm.expectRevert(BotledArbitrator.Commitment.selector);
        _reveal(cage, 6, 1, d[0], 1, 0, 0);
        vm.prank(d[0]);
        vm.expectRevert(BotledArbitrator.Commitment.selector);
        cage.reveal(6, 2, 10_000, 0, keccak256("t"), bytes32("wrong salt"));
        _reveal(cage, 6, 1, d[0], 2, 10_000, 0);
        vm.expectRevert(BotledArbitrator.Commitment.selector);
        _reveal(cage, 6, 1, d[0], 2, 10_000, 0); // no double reveal
        vm.expectRevert(BotledArbitrator.Commitment.selector);
        _reveal(cage, 6, 1, d[2], 3, 6_100, 5); // lane >= laneCount
        _reveal(cage, 6, 1, d[1], 3, 6_000, 1);
        // not everyone revealed -> no early close
        vm.expectRevert(BotledArbitrator.Phase_.selector);
        cage.closeRound(6);
        vm.warp(revealEnd + 1);
        vm.expectRevert(BotledArbitrator.Phase_.selector);
        _reveal(cage, 6, 1, d[2], 3, 6_000, 1);
        cage.closeRound(6); // 1 WORKER vs 1 SPLIT vs no-show -> no majority -> round 2
        (, uint8 round,) = _phase(cage, 6);
        assertEq(round, 2);
    }

    function testOffGridRevealRejected() public {
        BotledArbitrator cage = _seat("a");
        _open(cage, 7);
        vrf.fulfill(vrf.lastId(), 7);
        address[] memory d = _drawn(cage, 7, 1);
        _commit(cage, 7, 1, d[0], 3, 6_100, 0);
        (uint256 commitEnd,) = cage.windows(7);
        vm.warp(commitEnd + 1);
        vm.expectRevert(BotledArbitrator.Allocation.selector);
        _reveal(cage, 7, 1, d[0], 3, 6_100, 0);
    }

    function testNoShowSlashedRewardsGoToMajority() public {
        BotledArbitrator cage = _seat("a");
        _open(cage, 8);
        vrf.fulfill(vrf.lastId(), 8);
        address[] memory d = _drawn(cage, 8, 1);
        _commit(cage, 8, 1, d[0], 4, 5_000, 0);
        _commit(cage, 8, 1, d[1], 4, 5_000, 1);
        (uint256 commitEnd, uint256 revealEnd) = cage.windows(8);
        vm.warp(commitEnd + 1);
        _reveal(cage, 8, 1, d[0], 4, 5_000, 0);
        _reveal(cage, 8, 1, d[1], 4, 5_000, 1);
        vm.expectRevert(BotledArbitrator.Phase_.selector);
        cage.closeRound(8); // d[2] could still reveal
        vm.warp(revealEnd + 1);
        cage.closeRound(8);
        (,, uint64 dl) = _phase(cage, 8);
        vm.warp(dl + 1);
        uint256[3] memory before = [_bond(d[0]), _bond(d[1]), _bond(d[2])];
        uint256 fund = pool.rewardFund();
        cage.finalize(8);
        assertEq(before[2] - _bond(d[2]), 50e18, "no-show slashed");
        assertEq(_bond(d[0]) - before[0], 40e18, "(50 slash + 30 reward) / 2");
        assertEq(_bond(d[1]) - before[1], 40e18);
        assertEq(fund - pool.rewardFund(), 30e18, "fund pays only rewardPerRound");
        (, uint8 o) = _outcome(8);
        assertEq(o, 4, "MUTUAL 5000");
    }

    function testJuryNeedsDistinctProviders() public {
        BotledArbitrator cage = _seat("a");
        _open(cage, 9);
        vrf.fulfill(vrf.lastId(), 77);
        address[] memory d = _drawn(cage, 9, 1);
        for (uint256 i; i < 3; ++i) _commit(cage, 9, 1, d[i], 1, 0, 0); // all on lane 0 (anthropic)
        (uint256 commitEnd,) = cage.windows(9);
        vm.warp(commitEnd + 1);
        for (uint256 i; i < 3; ++i) _reveal(cage, 9, 1, d[i], 1, 0, 0);
        cage.closeRound(9);
        (BotledArbitrator.Phase ph, uint8 round,) = _phase(cage, 9);
        assertEq(uint8(ph), uint8(BotledArbitrator.Phase.JURY), "unanimous but single provider -> does not count");
        assertEq(round, 2, "auto-escalated to the 7-juror round");
        assertEq(_drawn(cage, 9, 2).length, 0, "draw pending");
        assertEq(vrf.gasOf(vrf.lastId()), pool.callbackGas(7));
    }

    function testSplitJuryAutoEscalatesWithoutBond() public {
        BotledArbitrator cage = _seat("a");
        _open(cage, 10);
        vrf.fulfill(vrf.lastId(), 10);
        address[] memory d = _drawn(cage, 10, 1);
        _commit(cage, 10, 1, d[0], 1, 0, 0);
        _commit(cage, 10, 1, d[1], 2, 10_000, 1);
        _commit(cage, 10, 1, d[2], 3, 5_000, 0);
        (uint256 commitEnd,) = cage.windows(10);
        vm.warp(commitEnd + 1);
        _reveal(cage, 10, 1, d[0], 1, 0, 0);
        _reveal(cage, 10, 1, d[1], 2, 10_000, 1);
        _reveal(cage, 10, 1, d[2], 3, 5_000, 0);
        cage.closeRound(10);
        (, uint8 round,) = _phase(cage, 10);
        assertEq(round, 2);
        address[] memory d2 = _juryRound(cage, 10, 2, 3, 5_000);
        assertEq(d2.length, 7);
        (,, uint64 dl) = _phase(cage, 10);
        vm.warp(dl + 1);
        cage.finalize(10);
        (, uint8 o) = _outcome(10);
        assertEq(o, 3);
        // round-1 jurors: d[2] (SPLIT 5000) coherent with the final result, the others slashed as minority
        assertEq(_active(d[0]) + _active(d[1]) + _active(d[2]), 0);
    }

    // ================================================================ appeals

    function testAppealEscalates3to7to15() public {
        BotledArbitrator cage = _seat("a");
        _open(cage, 11);
        address poster = reg.poster();
        address worker = reg.worker();
        assertEq(_juryRound(cage, 11, 1, 1, 0).length, 3);
        vm.prank(address(0xBAD));
        vm.expectRevert(BotledArbitrator.Auth.selector);
        cage.appeal(11); // only the parties
        _appeal(cage, 11, worker);
        assertEq(vrf.gasOf(vrf.lastId()), pool.callbackGas(7));
        assertEq(_juryRound(cage, 11, 2, 2, 10_000).length, 7);
        _appeal(cage, 11, poster);
        assertEq(vrf.gasOf(vrf.lastId()), pool.callbackGas(15));
        vrf.fulfill(vrf.lastId(), 99);
        emit log_named_uint("gas VRF callback, 15 jurors", vrf.lastFulfillGas());
        assertLt(vrf.lastFulfillGas(), pool.callbackGas(15), "15-juror draw fits callback gas");
        address[] memory d3 = _drawn(cage, 11, 3);
        assertEq(d3.length, 15);
        for (uint256 i; i < 15; ++i) _commit(cage, 11, 3, d3[i], 2, 10_000, _lane(i));
        (uint256 commitEnd,) = cage.windows(11);
        vm.warp(commitEnd + 1);
        for (uint256 i; i < 15; ++i) _reveal(cage, 11, 3, d3[i], 2, 10_000, _lane(i));
        uint256 g = gasleft();
        cage.closeRound(11);
        emit log_named_uint("gas closeRound round 3 (rule + settle 3+7+15 jurors + bonds)", g - gasleft());

        (BotledArbitrator.Phase ph,,) = _phase(cage, 11);
        assertEq(uint8(ph), uint8(BotledArbitrator.Phase.RULED), "round 3 is final and executes immediately");
        (, uint8 o) = _outcome(11);
        assertEq(o, 2);
        vm.prank(worker);
        vm.expectRevert(BotledArbitrator.Phase_.selector);
        cage.appeal(11);
    }

    function testAppealBondsSettle() public {
        BotledArbitrator cage = _seat("a");
        _open(cage, 12);
        address poster = reg.poster();
        address worker = reg.worker();
        assertEq(cage.appealBond(12, 1), 0, "round 1 is automatic");
        assertEq(cage.appealBond(12, 2), 200e18);
        assertEq(cage.appealBond(12, 3), 400e18);

        _juryRound(cage, 12, 1, 1, 0); // round 1: POSTER_WINS
        _appeal(cage, 12, worker); // bond 200
        _juryRound(cage, 12, 2, 2, 10_000); // round 2 overturns: WORKER_WINS
        _appeal(cage, 12, poster); // bond 400
        uint256 fundBefore = pool.rewardFund();
        _juryRound(cage, 12, 3, 2, 10_000); // round 3 confirms WORKER_WINS -> executes

        assertEq(azl.balanceOf(worker), 10_000e18 + 200e18, "worker: bond refunded (won) + half of poster's 400");
        assertEq(azl.balanceOf(poster), 10_000e18 - 400e18, "poster forfeits");
        assertEq(azl.balanceOf(address(cage)), 0, "no token stuck in cage");
        assertEq(cage.heldBonds(), 0);
        // round 1 (3x POSTER) all minority: 60 slashed -> fund; round 2: 30 / 7; round 3: (30 + 200) / 15
        assertEq(
            pool.rewardFund(),
            fundBefore + 200e18 + 60e18 - 7 * (uint256(30e18) / 7) - 15 * (uint256(230e18) / 15),
            "reward fund accounting"
        );
    }

    // ================================================================ timeline

    /// Worst case: every phase runs to its last second, both appeals at the last second, VRF at its timeout,
    /// one no-show per round. Must end before Azzle's rulingDeadline minus the safety margin.
    function testWorstCaseFitsRulingWindow() public {
        BotledArbitrator cage = _seat("a");
        reg.open(module, 13, keccak256("ev"));
        (, , , , , uint64 T, , , ,) = module.disputes(13);
        vm.warp(T + 1);
        cage.openCase(13);
        (, , , , , , uint64 rulingDeadline, , ,) = module.disputes(13);
        assertEq(rulingDeadline, T + 48 hours);
        assertEq(config.worstCaseDuration(0), 32 hours);
        for (uint8 r = 1; r <= 3; ++r) {
            if (r > 1) {
                (, , uint64 appealEnd) = _phase(cage, 13);
                vm.warp(appealEnd); // last second of the appeal window
                _appeal(cage, 13, r == 2 ? reg.worker() : reg.poster());
            }
            (, , uint64 vrfDeadline) = _phase(cage, 13);
            vm.warp(vrfDeadline); // VRF answers at the timeout
            vrf.fulfill(vrf.lastId(), r);
            address[] memory d = _drawn(cage, 13, r);
            for (uint256 i; i < d.length; ++i) _commit(cage, 13, r, d[i], 2, 10_000, _lane(i));
            (uint256 commitEnd, uint256 revealEnd) = cage.windows(13);
            vm.warp(commitEnd + 1);
            for (uint256 i = 1; i < d.length; ++i) _reveal(cage, 13, r, d[i], 2, 10_000, _lane(i)); // juror 0 no-show
            vm.warp(revealEnd + 1);
            cage.closeRound(13);
        }
        (uint8 st, uint8 o) = _outcome(13);
        assertEq(st, 3);
        assertEq(o, 2);
        assertLe(block.timestamp, T + 31 hours, "worst case ~T+30h");
        assertLe(block.timestamp, rulingDeadline - 2 hours, "before rulingDeadline - safetyMargin");
        emit log_named_uint("worst-case seconds after evidenceDeadline", block.timestamp - T);
    }

    function testLateCaseShrinksAppealWindow() public {
        BotledArbitrator cage = _seat("a");
        reg.open(module, 14, keccak256("ev"));
        (, , , , , uint64 T, , , ,) = module.disputes(14);
        vm.warp(uint256(T) + 33 hours); // nobody opened the case for 33h
        cage.openCase(14);
        _juryRound(cage, 14, 1, 1, 0);
        (, , uint64 dl) = _phase(cage, 14);
        assertEq(dl, T + 40 hours, "appeal window clipped to hardStop - one round");
        vm.warp(dl);
        _appeal(cage, 14, reg.worker());
        _juryRound(cage, 14, 2, 1, 0);
        (, , uint64 dl2) = _phase(cage, 14);
        assertEq(dl2, block.timestamp, "no further round fits: zero appeal window");
        address poster = reg.poster();
        vm.prank(poster);
        vm.expectRevert(BotledArbitrator.TooLate.selector);
        cage.appeal(14);
        vm.warp(block.timestamp + 1);
        cage.finalize(14);
        (, uint8 o) = _outcome(14);
        assertEq(o, 1);

        // a case opened after hardStop - one round cannot start at all (Azzle timeout applies)
        reg.open(module, 15, keccak256("ev"));
        (, , , , , uint64 T2, , , ,) = module.disputes(15);
        vm.warp(uint256(T2) + 40 hours + 1);
        vm.expectRevert(BotledArbitrator.TooLate.selector);
        cage.openCase(15);
    }

    function testFactoryRejectsParamsExceedingRulingWindow() public {
        BotledConfig.Params memory p = _params();
        p.appealWindow = 15 hours; // 3*6 + 2*15 + 2 = 50h > 48h
        config.proposeParams(p);
        vm.warp(block.timestamp + 1 days + 1);
        config.activateParams();
        vm.expectRevert(BotledFactory.Unsupported.selector);
        factory.deployCage(address(module), CID, "x");
    }

    function testAzzleTimeoutSyncSlashesNoShows() public {
        BotledArbitrator cage = _seat("a");
        _open(cage, 16);
        for (uint8 r = 1; r <= 3; ++r) {
            vrf.fulfill(vrf.lastId(), r); // drawn, but nobody votes
            (, uint256 revealEnd) = cage.windows(16);
            vm.warp(revealEnd + 1);
            cage.closeRound(16); // auto-escalates
        }
        (BotledArbitrator.Phase ph, uint8 round,) = _phase(cage, 16);
        assertEq(uint8(ph), uint8(BotledArbitrator.Phase.APPEAL));
        assertEq(round, 3);
        vm.expectRevert(BotledArbitrator.Phase_.selector);
        cage.finalize(16);
        address[] memory d = _drawn(cage, 16, 3);
        uint256 b = _bond(d[0]);
        (, , , , , , uint64 rulingDeadline, , ,) = module.disputes(16);
        vm.warp(rulingDeadline + 1);
        module.timeout(16);
        cage.syncAzzleTimeout(16);
        assertLt(_bond(d[0]), b, "no-show slashed");
        assertEq(_active(d[0]), 0);
        (uint8 st, uint8 o) = _outcome(16);
        assertEq(st, 3);
        assertEq(o, 4, "Azzle timeout = MUTUAL refund");
    }

    // ================================================================ rule() into a mock ArbitrationModuleV2

    function testRuleCallIntoMockModule() public {
        BotledArbitrator cage = _deployCageFor(address(0x0F2), "mock", address(mockModule));
        mockModule.open(1, address(cage));
        vm.expectRevert(BotledArbitrator.Phase_.selector);
        cage.openCase(1); // evidence window still open
        vm.warp(block.timestamp + EVIDENCE + 1);
        cage.openCase(1);
        // inputHash is reproducible off-chain
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("BOTLED.v4"), block.chainid, address(mockModule), uint256(1), config.constitutionHash(CID), bytes32(0),
                address(0xA11CE), address(0xB0B), keccak256("pe"), keccak256("we")
            )
        );
        assertEq(_inputHash(cage, 1), expected, "inputHash");
        _juryRound(cage, 1, 1, 3, 6_000);
        (,, uint64 dl) = _phase(cage, 1);
        vm.warp(dl + 1);
        cage.finalize(1);
        assertEq(mockModule.ruleCalls(), 1);
        assertEq(mockModule.lastTask(), 1);
        assertEq(mockModule.lastOutcome(), 3, "SPLIT");
        assertEq(mockModule.lastBps(), 6_000);
        assertEq(mockModule.lastCaller(), address(cage));
        vm.expectRevert(BotledArbitrator.Phase_.selector);
        cage.finalize(1);
    }

    // ================================================================ E2E config: test token, small bonds, short windows

    function testE2EConfigTestTokenShortWindows() public {
        TestBondToken tok = new TestBondToken();
        BotledConfig.Params memory p;
        p.jurySizes = [uint8(1), 3, 3];
        p.minProviders = 1;
        p.vrfTimeout = 10 minutes;
        p.commitWindow = 10 minutes;
        p.revealWindow = 10 minutes;
        p.appealWindow = 10 minutes;
        p.safetyMargin = 30 minutes;
        p.appealBonds = [uint128(1e18), uint128(2e18)];
        p.noShowSlash = 0.5e18;
        p.minoritySlash = 0.2e18;
        address[] memory arbs = new address[](1);
        arbs[0] = address(mockModule);
        BotledConfig c2 = new BotledConfig(address(this), 1 days, p, _constitution(), _lanes(), arbs);
        BotledRunnerPool p2 = new BotledRunnerPool(address(c2), address(tok), address(vrf), 1e18, 1 hours, 100_000, 60_000, 3);
        BotledFactory f2 = new BotledFactory(c2, address(p2), address(0));
        c2.wire(address(f2), address(p2));
        assertEq(c2.worstCaseDuration(0), 140 minutes);
        for (uint256 i; i < 3; ++i) {
            address r = vm.addr(0x2000 + i);
            tok.mint(r, 5e18);
            vm.startPrank(r);
            tok.approve(address(p2), type(uint256).max);
            p2.registerRunner(3e18);
            vm.stopPrank();
        }
        // genesis is live immediately: no timelock wait for the first E2E run
        BotledArbitrator cage = BotledArbitrator(payable(f2.deployCage(address(mockModule), 0, "e2e")));
        assertEq(address(cage.bondToken()), address(tok));
        mockModule.open(7, address(cage));
        vm.warp(block.timestamp + EVIDENCE + 1);
        cage.openCase{value: 0.01 ether}(7); // caller funds VRF
        assertEq(address(p2).balance, 0.01 ether - vrf.price());
        vrf.fulfill(vrf.lastId(), 1);
        address j = p2.drawnRunners(address(cage), cage.drawId(7, 1))[0];
        bytes32 h = keccak256(abi.encode(address(cage), uint256(7), uint8(1), j, _inputHash(cage, 7), uint8(1), uint16(0), uint8(0), keccak256("t"), bytes32("s")));
        vm.prank(j);
        cage.commit(7, h);
        vm.warp(block.timestamp + 10 minutes + 1);
        vm.prank(j);
        cage.reveal(7, 1, 0, 0, keccak256("t"), bytes32("s"));
        cage.closeRound(7);
        // worker appeals with the test token
        address worker = mockModule.worker();
        tok.mint(worker, 10e18);
        vm.startPrank(worker);
        tok.approve(address(cage), type(uint256).max);
        cage.appeal(7);
        vm.stopPrank();
        assertEq(tok.balanceOf(address(cage)), 1e18);
        vrf.fulfill(vrf.lastId(), 2);
        address[] memory d = p2.drawnRunners(address(cage), cage.drawId(7, 2));
        assertEq(d.length, 3);
        for (uint256 i; i < 3; ++i) {
            bytes32 hh = keccak256(abi.encode(address(cage), uint256(7), uint8(2), d[i], _inputHash(cage, 7), uint8(2), uint16(10_000), uint8(0), keccak256("t"), bytes32("s")));
            vm.prank(d[i]);
            cage.commit(7, hh);
        }
        vm.warp(block.timestamp + 10 minutes + 1);
        for (uint256 i; i < 3; ++i) {
            vm.prank(d[i]);
            cage.reveal(7, 2, 10_000, 0, keccak256("t"), bytes32("s"));
        }
        cage.closeRound(7);
        vm.warp(block.timestamp + 10 minutes + 1);
        cage.finalize(7);
        assertEq(mockModule.lastOutcome(), 2);
        assertEq(tok.balanceOf(worker), 10e18, "appeal won: bond refunded");
    }

    // ================================================================ config governance

    function testConfigTimelockAndRevoke() public {
        BotledConfig.Params memory p = _params();
        address[] memory none = new address[](0);
        vm.expectRevert(BotledConfig.Config.selector);
        new BotledConfig(address(this), 1 hours, p, _constitution(), _lanes(), none); // timelock < 1 day
        BotledConfig.Lane[] memory dup = new BotledConfig.Lane[](2);
        dup[0] = BotledConfig.Lane("claude-opus-5", "anthropic");
        dup[1] = BotledConfig.Lane("claude-sonnet-5", "anthropic");
        vm.expectRevert(BotledConfig.Config.selector);
        new BotledConfig(address(this), 1 days, p, _constitution(), dup, none); // lanes need distinct providers
        p.jurySizes = [uint8(3), 4, 15];
        vm.expectRevert(BotledConfig.Config.selector);
        config.proposeParams(p); // even sizes rejected

        p = _params();
        p.noShowSlash = 99e18;
        config.proposeParams(p);
        vm.expectRevert(BotledConfig.Timelocked.selector);
        config.activateParams();
        vm.warp(block.timestamp + 1 days);
        config.activateParams();
        assertEq(config.getParams(config.currentParamsId()).noShowSlash, 99e18);

        uint32 id = config.proposeConstitution(_constitution(), _lanes());
        assertFalse(config.isConstitutionActive(id), "new constitution is timelocked");
        vm.prank(address(0xBAD));
        vm.expectRevert();
        config.revokeConstitution(CID);
        config.revokeConstitution(CID);
        vm.expectRevert(BotledFactory.Unsupported.selector);
        factory.deployCage(address(module), CID, "x");
        vm.expectRevert(BotledConfig.Config.selector);
        config.wire(address(factory), address(pool)); // wiring is one-shot
    }

    // ================================================================ runner reference script parity

    /// Vectors printed by `node --experimental-strip-types runner/botled-runner.ts --vectors`.
    function testRunnerHashesMatchSolidity() public {
        BotledConfig.Constitution memory c;
        c.promptTemplateHash = 0xd3d23aabe2afa7c6cd2d7d2e57ad4b9404ead9ba1261e5481f765b774d5df3ce;
        c.rubricHash = 0x7b67f0176e968d438935d94d0c269ddcfa8d9a97d60a891859dcbb9a659bf1c7;
        c.schemaHash = 0xa3856bc318663d743379377e0f41e735103cb1528c2d0160083a6fbcf3e93e08;
        c.decodingHash = 0x076a9431cfd19de30f71084669e5afb11d13ea512c38cd93d68f73ce3ac21189;
        BotledConfig c2 = new BotledConfig(address(this), 1 days, _params(), c, _lanes(), new address[](0));
        assertEq(c2.constitutionHash(0), 0x478636f68141a2b743a74f504116af95148734bf9fd8e43053ff351cf97d89f4, "constitutionHash");
        bytes32 commitH = keccak256(
            abi.encode(address(1), uint256(7), uint8(1), address(2), bytes32(uint256(0x11)), uint8(2), uint16(10_000), uint8(1),
                bytes32(uint256(0x22)), bytes32(uint256(0x33)))
        );
        assertEq(commitH, 0x7c1f2b31457a693704d98500c73bfa397cf11b60efe47f9c4226b2b76049dc4e, "commitment");
        bytes32 inH = keccak256(
            abi.encode(keccak256("BOTLED.v4"), uint256(8453), address(3), uint256(7), c2.constitutionHash(0), bytes32(0),
                address(0xA11CE), address(0xB0B), bytes32(uint256(0x44)), bytes32(uint256(0x55)))
        );
        assertEq(inH, 0x2496dfb12528214abefb19593cef6d67f9f55f99bc6886c10b61c4b8b76648c1, "inputHash");
    }

    // ================================================================ gas

    function testGasPerDispute() public {
        BotledArbitrator cage = _seat("a");
        reg.open(module, 17, keccak256("ev"));
        vm.warp(block.timestamp + EVIDENCE + 1);
        uint256 g = gasleft();
        cage.openCase(17);
        emit log_named_uint("gas openCase (beginRuling + VRF request)", g - gasleft());
        vrf.fulfill(vrf.lastId(), 17);
        emit log_named_uint("gas VRF callback, 3 jurors (paid via VRF fee)", vrf.lastFulfillGas());
        address[] memory d = _drawn(cage, 17, 1);
        uint256 commitGas;
        for (uint256 i; i < 3; ++i) {
            bytes32 h = _commitment(cage, 17, 1, d[i], 2, 10_000, _lane(i));
            vm.prank(d[i]);
            g = gasleft();
            cage.commit(17, h);
            commitGas += g - gasleft();
        }
        emit log_named_uint("gas commit (avg)", commitGas / 3);
        (uint256 commitEnd,) = cage.windows(17);
        vm.warp(commitEnd + 1);
        uint256 revealGas;
        for (uint256 i; i < 3; ++i) {
            vm.prank(d[i]);
            g = gasleft();
            cage.reveal(17, 2, 10_000, _lane(i), keccak256("t"), _salt(d[i], 1));
            revealGas += g - gasleft();
        }
        emit log_named_uint("gas reveal (avg)", revealGas / 3);
        g = gasleft();
        cage.closeRound(17);
        emit log_named_uint("gas closeRound", g - gasleft());
        (,, uint64 dl) = _phase(cage, 17);
        vm.warp(dl + 1);
        g = gasleft();
        cage.finalize(17);
        emit log_named_uint("gas finalize (rule + settle, Azzle deps mocked)", g - gasleft());

        // VRF callback for 7 and 15 jurors
        reg.open(module, 18, keccak256("ev"));
        vm.warp(block.timestamp + EVIDENCE + 1);
        cage.openCase(18);
        _juryRound(cage, 18, 1, 1, 0);
        _appeal(cage, 18, reg.worker());
        vrf.fulfill(vrf.lastId(), 18);
        emit log_named_uint("gas VRF callback, 7 jurors", vrf.lastFulfillGas());
        assertLt(vrf.lastFulfillGas(), pool.callbackGas(7));
    }

    // ================================================================ seat / gate (unchanged behaviour)

    function testNonFactoryCannotJoinOrDraw() public {
        FakeCage fake = new FakeCage();
        azl.mint(address(fake), MIN);
        vm.deal(address(this), 1 ether);
        vm.expectRevert(PanelJoinGateV2.NotAdmitted.selector);
        fake.bondAndJoin{value: PFAND + 0.0001 ether}(vault, azl, gate, address(module), MIN);
        vm.expectRevert(BotledRunnerPool.NotCage.selector);
        fake.draw(pool);
    }

    function testJoinDelayEpochAndCap() public {
        address op = address(0x0F1);
        BotledArbitrator a = _deployCage(op, "a");
        BotledArbitrator b = _deployCage(op, "b");
        BotledArbitrator c = _deployCage(op, "c");
        uint256 id = _requestJoin(a, op);
        vm.expectRevert(PanelJoinGateV2.NotReady.selector);
        gate.activate(address(a), address(module));
        uint256 costB = gate.joinCost(address(b));
        vm.prank(op);
        vm.expectRevert(PanelJoinGateV2.EpochUsed.selector);
        b.joinPanel{value: costB}(IAzzlePanelGate(address(gate)));
        uint256 word = 12345 days + 7;
        vrf.fulfill(id, word);
        (uint64 requestedAt, uint64 readyAt,) = gate.joins(address(a), address(module));
        assertEq(readyAt, requestedAt + 1 days + uint64(word % (2 days + 1)));
        vm.warp(readyAt);
        gate.activate(address(a), address(module));
        assertTrue(module.authorized(address(a)));
        _joinFully(b, op, 1);
        _addHuman();
        vm.warp(block.timestamp + 1 days);
        uint256 costC = gate.joinCost(address(c));
        vm.prank(op);
        vm.expectRevert(PanelJoinGateV2.PanelFull.selector);
        c.joinPanel{value: costC}(IAzzlePanelGate(address(gate)));
    }

    function _addHuman() internal {
        azl.mint(human, MIN);
        vm.startPrank(human);
        azl.approve(address(vault), MIN);
        vault.bond(MIN);
        vm.stopPrank();
        safe.call(address(module), abi.encodeCall(ArbitrationModuleV2.addPanelMember, (human)));
    }

    function testPruneIneligibleAndForfeitEarlyExit() public {
        address op = address(0x0F1);
        BotledArbitrator a = _deployCage(op, "a");
        _joinFully(a, op, 0);
        _addHuman();
        vm.expectRevert(PanelJoinGateV2.NotPrunable.selector);
        gate.prune(address(module), address(a));
        vm.prank(op);
        a.schedulePanelExit();
        uint256 sinkBefore = address(pool).balance;
        vm.prank(address(0xDEAD));
        gate.prune(address(module), address(a));
        assertFalse(module.authorized(address(a)));
        vm.prank(op);
        a.withdrawPfand(IAzzlePanelGate(address(gate)));
        assertEq(address(pool).balance, sinkBefore + PFAND);
    }

    function testSybilOperatorHasNoRulingPower() public {
        address attacker = address(0xBAD);
        BotledArbitrator cage = _deployCage(attacker, "evil");
        _joinFully(cage, attacker, 0);
        _open(cage, 19);
        vrf.fulfill(vrf.lastId(), 19);
        vm.startPrank(attacker);
        vm.expectRevert(BotledArbitrator.Auth.selector);
        cage.commit(19, bytes32(uint256(1))); // operator is not a drawn runner
        vm.expectRevert(BotledArbitrator.Phase_.selector);
        cage.appeal(19); // nothing to appeal; later only poster/worker
        vm.expectRevert(BotledArbitrator.Phase_.selector);
        cage.finalize(19);
        vm.expectRevert(BotledRunnerPool.NotCage.selector);
        pool.settleDraw(19, new uint256[](0), new bool[](0), 0);
        vm.expectRevert(BotledArbitrator.Init.selector);
        cage.initialize(address(module), CID, attacker);
        vm.stopPrank();
        BotledArbitrator impl = BotledArbitrator(payable(factory.implementation()));
        vm.expectRevert(BotledArbitrator.Init.selector);
        impl.initialize(address(module), CID, attacker);
    }

    function testRunnerListNeedsBondAndEvict() public {
        address r = address(0x777);
        azl.mint(r, 1000e18);
        vm.startPrank(r);
        azl.approve(address(pool), type(uint256).max);
        vm.expectRevert(BotledRunnerPool.Runner_.selector);
        pool.registerRunner(1);
        pool.registerRunner(100e18);
        pool.scheduleRunnerExit();
        vm.warp(block.timestamp + 7 days);
        pool.withdrawRunner(100e18);
        vm.stopPrank();
        uint256 before = pool.runnerCount();
        pool.evict(r);
        assertEq(pool.runnerCount(), before - 1);
    }

    function testCageJoinsDeployedGateDirectly() public {
        PanelJoinGate v1 = new PanelJoinGate(address(safe), PFAND, address(module), address(module2));
        safe.enableModule(address(v1));
        address op = address(0x5AFE);
        BotledArbitrator cage = _deployCage(op, "v1");
        vm.prank(op);
        cage.joinPanel{value: PFAND}(IAzzlePanelGate(address(v1)));
        assertTrue(module.authorized(address(cage)));
    }
}
