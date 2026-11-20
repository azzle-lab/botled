// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {
    IAzzleArbitrationV2, IAzzleTaskParties, IAzzleBondVaultV2, IAzzlePanelGate, IAzzleTaskScope
} from "./interfaces/IAzzle.sol";
import {BotledConfig} from "./BotledConfig.sol";
import {BotledRunnerPool} from "./BotledRunnerPool.sol";

/// @title Botled v4 — one arbitrator seat on an Azzle panel (EIP-1167 clone, no admin, no upgrade)
/// @notice Pure jury design, no TEE and no human:
///         round 1: VRF draws jurySizes[0] runners from the global BotledRunnerPool, commit -> reveal,
///         majority (outcome, workerBps) stands. Poster or worker may appeal (bonded) to round 2 and 3
///         (e.g. 3 -> 7 -> 15). Round 3 is final and executes immediately. Everything is clipped so the
///         `rule` call lands before Azzle's rulingDeadline minus a safety margin.
///         The `operator` only funds the Azzle panel bond / pfand and gets them back.
contract BotledArbitrator is ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Phase { NONE, JURY, APPEAL, RULED }

    uint8 internal constant NONE_ = 0;
    uint8 internal constant POSTER_WINS = 1;
    uint8 internal constant WORKER_WINS = 2;
    uint8 internal constant SPLIT = 3;
    uint8 internal constant MUTUAL = 4;
    uint8 internal constant ST_EVIDENCE = 1;
    uint8 internal constant ST_RULING = 2;
    uint8 internal constant ST_SETTLED = 3;
    uint8 public constant FINAL_ROUND = 3;
    uint16 public constant SPLIT_STEP_BPS = 500;
    uint16 public constant NEUTRAL_BAND_BPS = 1_000;
    bytes32 public constant DOMAIN = keccak256("BOTLED.v4");

    struct Case {
        Phase phase;
        uint8 round;          // 1..3
        bool hasResult;
        uint32 paramsId;
        uint64 deadline;      // VRF timeout (JURY) or appeal window end (APPEAL)
        uint64 hardStop;      // Azzle rulingDeadline - safetyMargin
        bytes32 inputHash;
        bytes32 result;       // standing result keccak(outcome, bps)
        address poster;
        address worker;
    }

    struct Round {
        uint8 revealed;
        uint8 leaderCount;
        bytes32 leaderVote;
        address appellant;     // 0 = automatic round
        uint128 bond;
        bytes32 appealedResult;
    }

    struct Tally {
        uint8 count;
        uint8 laneMask; // bit i = some voter for this result used lane i
    }

    // shared by all clones (immutables live in the implementation's code)
    BotledConfig public immutable config;
    BotledRunnerPool public immutable pool;
    IERC20 public immutable bondToken; // appeal bonds (same token as runner bonds)
    address public immutable factory;
    IAzzleTaskScope public immutable scopeRegistry;

    // per clone
    IAzzleArbitrationV2 public arbitration;
    IAzzleBondVaultV2 public vault;
    IERC20 public azl; // Azzle panel bond token (vault.azl())
    uint32 public constitutionId;
    uint8 public laneCount;
    address public operator;

    mapping(uint256 => Case) public cases;
    mapping(uint256 => mapping(uint8 => Round)) public rounds;
    mapping(uint256 => mapping(uint8 => mapping(address => bytes32))) public commitments;
    mapping(uint256 => mapping(uint8 => mapping(address => bytes32))) public votes;
    mapping(uint256 => mapping(uint8 => mapping(bytes32 => Tally))) public tallies;
    uint256 public heldBonds;

    event CaseOpened(uint256 indexed taskId, uint32 constitutionId, uint32 paramsId, bytes32 inputHash, uint64 hardStop);
    event RoundStarted(uint256 indexed taskId, uint8 round, uint8 jurors, address appellant, uint256 bond, bool drawRequested);
    event Committed(uint256 indexed taskId, uint8 round, address indexed runner);
    event Revealed(
        uint256 indexed taskId, uint8 round, address indexed runner, uint8 outcome, uint16 workerBps, uint8 lane, bytes32 transcriptHash
    );
    event RoundClosed(uint256 indexed taskId, uint8 round, bool majority, bytes32 result);
    event CageRuled(uint256 indexed taskId, uint8 outcome, uint16 workerBps, uint8 round);

    error Phase_();
    error Auth();
    error Allocation();
    error Commitment();
    error TooLate();
    error Init();

    constructor(address config_, address pool_, address factory_, address scopeRegistry_) {
        config = BotledConfig(config_);
        pool = BotledRunnerPool(payable(pool_));
        bondToken = BotledRunnerPool(payable(pool_)).bondToken();
        factory = factory_;
        scopeRegistry = IAzzleTaskScope(scopeRegistry_);
        operator = address(1); // lock the implementation
    }

    function initialize(address arbitration_, uint32 constitutionId_, address operator_) external {
        if (msg.sender != factory || operator != address(0) || operator_ == address(0)) revert Init();
        arbitration = IAzzleArbitrationV2(arbitration_);
        vault = IAzzleBondVaultV2(IAzzleArbitrationV2(arbitration_).bonds());
        azl = IERC20(vault.azl());
        constitutionId = constitutionId_;
        laneCount = uint8(config.laneCount(constitutionId_));
        operator = operator_;
    }

    modifier onlyOperator() { if (msg.sender != operator) revert Auth(); _; }

    receive() external payable {}

    // ================================================================ operator: seat only

    function topUpBond(uint256 target) public onlyOperator nonReentrant {
        uint256 have = vault.bonds(address(this));
        uint256 need = vault.reservedSlash(address(this)) + vault.assignmentReserve();
        uint256 min = vault.minimumBond();
        if (target < need) target = need;
        if (target < min) target = min;
        uint256 add = target > have ? target - have : (vault.withdrawReadyAt(address(this)) != 0 ? 1 : 0);
        if (add == 0) return;
        azl.safeTransferFrom(operator, address(this), add);
        azl.forceApprove(address(vault), add);
        vault.bond(add);
    }

    function joinPanel(IAzzlePanelGate gate) external payable onlyOperator {
        topUpBond(gate.bondTarget(address(arbitration)));
        gate.joinPanel{value: msg.value}(address(arbitration));
    }

    function schedulePanelExit() external onlyOperator { vault.scheduleWithdrawal(); }

    function withdrawPanelBond(uint256 amount) external onlyOperator nonReentrant {
        vault.withdraw(amount);
        azl.safeTransfer(operator, amount);
    }

    function withdrawPfand(IAzzlePanelGate gate) external onlyOperator nonReentrant {
        gate.withdrawEth();
        (bool ok,) = operator.call{value: address(this).balance}("");
        require(ok, "BL: eth");
    }

    // ================================================================ open

    /// @notice Permissionless once Azzle's evidence window closed. Any ETH sent tops up the pool's VRF fund.
    function openCase(uint256 taskId) external payable nonReentrant {
        Case storage c = cases[taskId];
        if (c.phase != Phase.NONE) revert Phase_();
        (, , address arb, bytes32 posterEv, bytes32 workerEv, uint64 evidenceDeadline, , uint8 status, ,) =
            arbitration.disputes(taskId);
        if (arb != address(this) || block.timestamp <= evidenceDeadline) revert Phase_();
        if (status == ST_EVIDENCE) arbitration.beginRuling(taskId);
        (, , , , , , uint64 rulingDeadline, uint8 s2, ,) = arbitration.disputes(taskId);
        if (s2 != ST_RULING) revert Phase_();
        _fundVrf();

        (c.poster, c.worker) = IAzzleTaskParties(arbitration.registry()).taskParties(taskId);
        uint32 pid = config.currentParamsId();
        BotledConfig.Params memory p = config.getParams(pid);
        c.paramsId = pid;
        c.hardStop = rulingDeadline > p.safetyMargin ? rulingDeadline - p.safetyMargin : 0;
        c.inputHash = _inputHash(taskId, c.poster, c.worker, posterEv, workerEv);
        emit CaseOpened(taskId, constitutionId, pid, c.inputHash, c.hardStop);
        if (!_roundFits(c, p)) revert TooLate(); // nothing fits any more: Azzle timeout applies
        _startRound(taskId, 1, address(0), 0, p);
    }

    /// @notice If the pool could not pay VRF when the round started, anyone may retry after topping it up.
    function retryDraw(uint256 taskId) external payable nonReentrant {
        Case storage c = cases[taskId];
        (uint64 requestedAt,,,) = pool.drawInfo(address(this), _drawId(taskId, c.round));
        BotledConfig.Params memory p = config.getParams(c.paramsId);
        if (c.phase != Phase.JURY || requestedAt != 0) revert Phase_();
        if (!_roundFits(c, p)) revert TooLate();
        _fundVrf();
        c.deadline = _min(block.timestamp + p.vrfTimeout, c.hardStop);
        if (!pool.requestDraw(_drawId(taskId, c.round), c.poster, c.worker, p.jurySizes[c.round - 1], c.deadline)) {
            revert Phase_();
        }
    }

    // ================================================================ appeal / jury

    function appealBond(uint256 taskId, uint8 round) public view returns (uint256) {
        if (round < 2 || round > FINAL_ROUND) return 0;
        return config.getParams(cases[taskId].paramsId).appealBonds[round - 2];
    }

    /// @notice Poster or worker escalates the standing result to the next (larger) jury.
    function appeal(uint256 taskId) external payable nonReentrant {
        Case storage c = cases[taskId];
        if (c.phase != Phase.APPEAL || block.timestamp > c.deadline || !c.hasResult) revert Phase_();
        if (msg.sender != c.poster && msg.sender != c.worker) revert Auth();
        uint8 r = c.round + 1;
        BotledConfig.Params memory p = config.getParams(c.paramsId);
        if (r > FINAL_ROUND || !_roundFits(c, p)) revert TooLate();
        uint128 bond = p.appealBonds[r - 2];
        if (bond > 0) bondToken.safeTransferFrom(msg.sender, address(this), bond);
        heldBonds += bond;
        _fundVrf();
        _startRound(taskId, r, msg.sender, bond, p);
    }

    /// @dev commitment = keccak256(abi.encode(cage, taskId, round, runner, inputHash, outcome, workerBps, lane, transcriptHash, salt))
    ///      lane = index into config.lanes(constitutionId): the (model, provider) pair the runner used (self-declared).
    function commit(uint256 taskId, bytes32 commitment) external {
        Case storage c = cases[taskId];
        (uint256 commitEnd,) = _windows(taskId, c);
        if (c.phase != Phase.JURY || commitEnd == 0 || block.timestamp > commitEnd) revert Phase_();
        uint8 r = c.round;
        if (!pool.isDrawn(address(this), _drawId(taskId, r), msg.sender) || commitments[taskId][r][msg.sender] != 0 || commitment == 0) {
            revert Auth();
        }
        commitments[taskId][r][msg.sender] = commitment;
        emit Committed(taskId, r, msg.sender);
    }

    function reveal(uint256 taskId, uint8 outcome, uint16 workerBps, uint8 lane, bytes32 transcriptHash, bytes32 salt) external {
        Case storage c = cases[taskId];
        (uint256 commitEnd, uint256 revealEnd) = _windows(taskId, c);
        if (c.phase != Phase.JURY || block.timestamp <= commitEnd || block.timestamp > revealEnd) revert Phase_();
        uint8 r = c.round;
        if (votes[taskId][r][msg.sender] != 0) revert Commitment();
        bytes32 expected = keccak256(
            abi.encode(address(this), taskId, r, msg.sender, c.inputHash, outcome, workerBps, lane, transcriptHash, salt)
        );
        if (commitments[taskId][r][msg.sender] != expected || lane >= laneCount) revert Commitment();
        _validate(outcome, workerBps);
        bytes32 vote = keccak256(abi.encode(outcome, workerBps));
        votes[taskId][r][msg.sender] = vote;
        Tally storage t = tallies[taskId][r][vote];
        t.count++;
        t.laneMask |= uint8(1 << lane);
        Round storage rd = rounds[taskId][r];
        rd.revealed++;
        if (t.count > rd.leaderCount) { rd.leaderCount = t.count; rd.leaderVote = vote; }
        emit Revealed(taskId, r, msg.sender, outcome, workerBps, lane, transcriptHash);
    }

    /// @notice Permissionless. Early once every drawn runner revealed; otherwise after the reveal window / VRF timeout.
    function closeRound(uint256 taskId) external nonReentrant {
        Case storage c = cases[taskId];
        if (c.phase != Phase.JURY) revert Phase_();
        uint8 r = c.round;
        (, uint64 fulfilledAt, uint256 drawnCount,) = pool.drawInfo(address(this), _drawId(taskId, r));
        if (fulfilledAt == 0) {
            if (block.timestamp <= c.deadline) revert Phase_(); // VRF still pending
        } else {
            (, uint256 revealEnd) = _windows(taskId, c);
            if (block.timestamp <= revealEnd && rounds[taskId][r].revealed < drawnCount) revert Phase_();
        }
        BotledConfig.Params memory p = config.getParams(c.paramsId);
        Round storage rd = rounds[taskId][r];
        // absolute majority of the FULL jury size (missing seats / no-shows count against) + lane diversity
        bool majority = uint256(rd.leaderCount) * 2 > p.jurySizes[r - 1] && _outcomeOf(rd.leaderVote) != NONE_
            && _popcount(tallies[taskId][r][rd.leaderVote].laneMask) >= p.minProviders;
        if (majority) {
            c.result = rd.leaderVote;
            c.hasResult = true;
        }
        emit RoundClosed(taskId, r, majority, c.result);

        if (r == FINAL_ROUND) {
            if (c.hasResult) return _execute(taskId);
            c.phase = Phase.APPEAL; // nothing decidable: Azzle timeout applies, then syncAzzleTimeout
            c.deadline = c.hardStop;
            return;
        }
        if (!c.hasResult) {
            // no standing result (jury split / no VRF): escalate automatically, without bond, if it fits
            if (_roundFits(c, p)) return _startRound(taskId, r + 1, address(0), 0, p);
            c.phase = Phase.APPEAL;
            c.deadline = c.hardStop;
            return;
        }
        c.phase = Phase.APPEAL;
        c.deadline = _appealDeadline(c, p);
    }

    /// @notice Executes the standing result once the appeal window passed unappealed.
    function finalize(uint256 taskId) external nonReentrant {
        Case storage c = cases[taskId];
        if (c.phase != Phase.APPEAL || block.timestamp <= c.deadline || !c.hasResult) revert Phase_();
        _execute(taskId);
    }

    /// @notice Cleanup after Azzle's own `timeout` settled a dispute the cage could not rule.
    function syncAzzleTimeout(uint256 taskId) external nonReentrant {
        Case storage c = cases[taskId];
        if (c.phase == Phase.NONE || c.phase == Phase.RULED) revert Phase_();
        (, , , , , , , uint8 s, ,) = arbitration.disputes(taskId);
        if (s != ST_SETTLED) revert Phase_();
        c.phase = Phase.RULED;
        BotledConfig.Params memory p = config.getParams(c.paramsId);
        for (uint8 r = 1; r <= c.round; ++r) {
            Round storage rd = rounds[taskId][r];
            if (rd.bond > 0) { heldBonds -= rd.bond; bondToken.safeTransfer(rd.appellant, rd.bond); }
            _settleDraw(taskId, r, 0, 0, p);
        }
    }

    // ================================================================ internals

    function _startRound(uint256 taskId, uint8 r, address appellant, uint128 bond, BotledConfig.Params memory p) internal {
        Case storage c = cases[taskId];
        Round storage rd = rounds[taskId][r];
        rd.appellant = appellant;
        rd.appealedResult = c.result;
        rd.bond = bond;
        c.round = r;
        c.phase = Phase.JURY;
        c.deadline = _min(block.timestamp + p.vrfTimeout, c.hardStop);
        uint8 n = p.jurySizes[r - 1];
        bool ok = pool.requestDraw(_drawId(taskId, r), c.poster, c.worker, n, c.deadline); // false => retryDraw / timeout
        emit RoundStarted(taskId, r, n, appellant, bond, ok);
    }

    function _execute(uint256 taskId) internal {
        Case storage c = cases[taskId];
        c.phase = Phase.RULED;
        (uint8 o, uint16 bps) = _decode(c.result);
        arbitration.rule(taskId, o, bps); // Azzle re-validates and settles escrow -> registry -> reputation -> bonds
        emit CageRuled(taskId, o, bps, c.round);

        // Appeal bonds: appellant gets it back if the final result differs from what they appealed.
        // Otherwise forfeited: half to the other party, half to the coherent jurors of the final round.
        uint256 bonus;
        for (uint8 r = 2; r <= c.round; ++r) {
            Round storage rd = rounds[taskId][r];
            if (rd.bond == 0) continue;
            heldBonds -= rd.bond;
            if (c.result != rd.appealedResult) {
                bondToken.safeTransfer(rd.appellant, rd.bond);
            } else {
                uint256 half = rd.bond / 2;
                bondToken.safeTransfer(rd.appellant == c.poster ? c.worker : c.poster, half);
                bonus += rd.bond - half;
            }
        }
        if (bonus > 0) {
            bondToken.forceApprove(address(pool), bonus);
            pool.fundRewards(bonus);
        }
        BotledConfig.Params memory p = config.getParams(c.paramsId);
        for (uint8 r = 1; r <= c.round; ++r) _settleDraw(taskId, r, c.result, r == c.round ? bonus : 0, p);
    }

    /// @dev No-show => noShowSlash; vote != final result => minoritySlash; vote == final result => share of
    ///      this draw's slashes + rewardPerRound (+ forfeited appeal bonds in the final round).
    function _settleDraw(uint256 taskId, uint8 r, bytes32 finalVote, uint256 bonus, BotledConfig.Params memory p) internal {
        uint256 id = _drawId(taskId, r);
        (uint64 requestedAt,,, bool settled) = pool.drawInfo(address(this), id);
        if (requestedAt == 0 || settled) return;
        address[] memory list = pool.drawnRunners(address(this), id);
        uint256[] memory slashes = new uint256[](list.length);
        bool[] memory rewarded = new bool[](list.length);
        for (uint256 i; i < list.length; ++i) {
            bytes32 v = votes[taskId][r][list[i]];
            if (v == 0) slashes[i] = p.noShowSlash;
            else if (finalVote != 0 && v != finalVote) slashes[i] = p.minoritySlash;
            rewarded[i] = finalVote != 0 && v == finalVote;
        }
        pool.settleDraw(id, slashes, rewarded, finalVote == 0 ? 0 : uint256(p.rewardPerRound) + bonus);
    }

    function _fundVrf() internal {
        if (msg.value == 0) return;
        (bool ok,) = address(pool).call{value: msg.value}("");
        require(ok, "BL: vrf");
    }

    function _roundLen(BotledConfig.Params memory p) internal pure returns (uint256) {
        return uint256(p.vrfTimeout) + p.commitWindow + p.revealWindow;
    }

    function _roundFits(Case storage c, BotledConfig.Params memory p) internal view returns (bool) {
        return block.timestamp + _roundLen(p) <= c.hardStop;
    }

    /// @dev Appeal window is shortened (down to zero) so a further round still fits before hardStop.
    function _appealDeadline(Case storage c, BotledConfig.Params memory p) internal view returns (uint64) {
        uint256 roundLen = _roundLen(p);
        uint256 latest = c.hardStop > roundLen ? c.hardStop - roundLen : 0;
        uint256 end = block.timestamp + p.appealWindow;
        if (end > latest) end = latest > block.timestamp ? latest : block.timestamp;
        return uint64(end);
    }

    function _windows(uint256 taskId, Case storage c) internal view returns (uint256 commitEnd, uint256 revealEnd) {
        (, uint64 f,,) = pool.drawInfo(address(this), _drawId(taskId, c.round));
        if (f == 0) return (0, 0);
        BotledConfig.Params memory p = config.getParams(c.paramsId);
        revealEnd = _min(uint256(f) + p.commitWindow + p.revealWindow, c.hardStop);
        commitEnd = _min(uint256(f) + p.commitWindow, revealEnd);
    }

    /// @notice (commitEnd, revealEnd) of the current round; (0, 0) while the draw is pending.
    function windows(uint256 taskId) external view returns (uint256, uint256) { return _windows(taskId, cases[taskId]); }

    function casePhase(uint256 taskId) external view returns (uint8) { return uint8(cases[taskId].phase); }

    function drawId(uint256 taskId, uint8 r) external pure returns (uint256) { return _drawId(taskId, r); }

    function _drawId(uint256 taskId, uint8 r) internal pure returns (uint256) { return (taskId << 8) | r; }

    function _min(uint256 a, uint256 b) internal pure returns (uint64) { return uint64(a < b ? a : b); }

    function _popcount(uint8 x) internal pure returns (uint8 n) {
        for (; x != 0; x &= x - 1) ++n;
    }

    function _inputHash(uint256 taskId, address poster, address worker, bytes32 posterEv, bytes32 workerEv)
        internal
        view
        returns (bytes32)
    {
        bytes32 scopeHash =
            address(scopeRegistry) == address(0) ? bytes32(0) : keccak256(bytes(scopeRegistry.scopeOf(taskId)));
        return keccak256(
            abi.encode(
                DOMAIN, block.chainid, address(arbitration), taskId, config.constitutionHash(constitutionId), scopeHash,
                poster, worker, posterEv, workerEv
            )
        );
    }

    function _validate(uint8 o, uint16 b) internal pure {
        bool ok = (o == NONE_ && b == 0) || (o == POSTER_WINS && b == 0) || (o == WORKER_WINS && b == 10_000)
            || (o == SPLIT && b >= NEUTRAL_BAND_BPS && b <= 10_000 - NEUTRAL_BAND_BPS && b % SPLIT_STEP_BPS == 0)
            || (o == MUTUAL && (b == 0 || b == 5_000));
        if (!ok) revert Allocation();
    }

    function _outcomeOf(bytes32 v) internal pure returns (uint8 o) { (o,) = _decode(v); }

    function _decode(bytes32 v) internal pure returns (uint8, uint16) {
        if (v == keccak256(abi.encode(POSTER_WINS, uint16(0)))) return (POSTER_WINS, 0);
        if (v == keccak256(abi.encode(WORKER_WINS, uint16(10_000)))) return (WORKER_WINS, 10_000);
        if (v == keccak256(abi.encode(MUTUAL, uint16(0)))) return (MUTUAL, 0);
        if (v == keccak256(abi.encode(MUTUAL, uint16(5_000)))) return (MUTUAL, 5_000);
        for (uint16 b = NEUTRAL_BAND_BPS; b <= 10_000 - NEUTRAL_BAND_BPS; b += SPLIT_STEP_BPS) {
            if (v == keccak256(abi.encode(SPLIT, b))) return (SPLIT, b);
        }
        return (NONE_, 0);
    }
}
