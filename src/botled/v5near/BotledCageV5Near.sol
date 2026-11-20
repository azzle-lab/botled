// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {
    IAzzleArbitrationV2, IAzzleTaskParties, IAzzleBondVaultV2, IAzzleTaskScope
} from "../interfaces/IAzzle.sol";
import {BotledConfig} from "../BotledConfig.sol";
import {BotledRunnerPoolNear} from "./BotledRunnerPoolNear.sol";
import {INearConfig, INearVerifier} from "./interfaces/IBotledNear.sol";
import {CageSeat, IBotledPanelOwnerSeatN} from "./lib/CageSeat.sol";
import {CageVotes} from "./lib/CageVotes.sol";
import {CageSettle, IDrawSink} from "./lib/CageSettle.sol";

/// @title Botled v5/NEAR cage — one self-serve arbitrator seat on BOTH Azzle panels, every vote a proven LLM output
/// @notice Same seat, case, VRF-jury, appeal (3 -> 7 -> 15) and Azzle routing mechanics as BotledCageV5. Changed:
///           * a reveal is accepted only together with a NEAR AI receipt (request bytes, response bytes, gateway or
///             model-TEE signature over sha256(request):sha256(response)) that BotledNearVerifier checks on-chain:
///             the request must be exactly HEAD(lane) || juror line || USER(case) || TAIL(lane) — pinned model,
///             pinned constitution prompt + decoding, this case's Azzle evidence, this runner and round — and the
///             signed response must contain the revealed (outcome, workerBps);
///           * USER(case) is bound once per case by anyone (`bindEvidence`) from the raw documents whose keccak256
///             are Azzle's evidence hashes (BotledEvidence convention) and the on-chain task scope;
///           * no minority slash and no runner bond; no-shows are recorded in BotledRunnerPoolNear (suspension until
///             the NEAR registry has charged the penalty from the runner's budget);
///           * commits can be relayed with the runner's EIP-712 signature (`commitFor`), reveals are permissionless:
///             runners controlled by NEAR Chain Signatures never need Base ETH.
///         The operator has no power over cases: it can only fund, seat and unseat the cage.
contract BotledCageV5Near is ReentrancyGuard {
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
    uint8 internal constant VERSION = 5;
    uint256 internal constant MAX_TASK_ID = (1 << 240) - 1;
    bytes32 public constant DOMAIN = keccak256("BOTLED.v5near");
    /// @dev votes[] marker for a liveness-only reveal (runner's own NEAR AI key, no sponsor co-signature)
    bytes32 internal constant LIVENESS = bytes32(uint256(1));


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

    struct Tally {
        uint8 count;
        uint8 laneMask;
    }

    /// @dev Azzle evidence hashes captured at openCase + the bound USER(case) request piece.
    struct Evidence {
        bytes32 posterEv;
        bytes32 workerEv;
        bytes32 scopeHash;     // keccak256(scope text), 0 = no scope source
        bytes32 userHash;      // keccak256(escaped user text), 0 = not bound yet
        uint32 userLen;
        uint64 boundAt;
    }

    // ------------------------------------------------ shared by all clones (implementation code)
    BotledConfig public immutable config;              // params + supported Azzle modules (deployed v4 config)
    INearConfig public immutable nearConfig;      // NEAR AI keys + request templates (timelocked)
    INearVerifier public immutable verifier;      // stateless receipt check
    BotledRunnerPoolNear public immutable pool;
    IERC20 public immutable bondToken;      // appeal bonds + rewards (pool reward token)
    address public immutable factory;
    IBotledPanelOwnerSeatN public immutable panelOwner;
    IAzzleArbitrationV2 public immutable micro;    // module index 0
    IAzzleArbitrationV2 public immutable standard; // module index 1
    IAzzleBondVaultV2 public immutable microVault;
    IAzzleBondVaultV2 public immutable standardVault;
    IERC20 public immutable azl;            // Azzle panel bond token (both vaults)
    IAzzleTaskScope public immutable microScope;    // optional, 0 = no on-chain scope binding
    IAzzleTaskScope public immutable standardScope;

    // ------------------------------------------------ per clone
    uint32 public constitutionId;
    uint8 public laneCount;
    address public operator;

    /// @dev key = caseKey(arbitration, taskId)
    mapping(bytes32 => Case) public cases;
    mapping(bytes32 => mapping(uint8 => CageSettle.Round)) public rounds;
    mapping(bytes32 => mapping(uint8 => mapping(address => bytes32))) public commitments;
    mapping(bytes32 => mapping(uint8 => mapping(address => bytes32))) public votes;
    mapping(bytes32 => mapping(uint8 => mapping(bytes32 => Tally))) public tallies;
    mapping(bytes32 => Evidence) public evidence;
    uint256 public heldBonds;

    event CaseOpened(address indexed arbitration, uint256 indexed taskId, uint32 constitutionId, uint32 paramsId, bytes32 inputHash, uint64 hardStop);
    event RoundStarted(address indexed arbitration, uint256 indexed taskId, uint8 round, uint8 jurors, address appellant, uint256 bond, bool drawRequested);
    event Committed(address indexed arbitration, uint256 indexed taskId, uint8 round, address indexed runner);
    event Revealed(
        address indexed arbitration, uint256 indexed taskId, uint8 round, address indexed runner, uint8 outcome, uint16 workerBps,
        uint8 lane, bytes32 requestSha256, bytes32 responseSha256, uint32 signerId, uint32 sponsorId, bool counted
    );
    event EvidenceBound(address indexed arbitration, uint256 indexed taskId, bytes32 userHash, uint32 userLen);
    event RoundClosed(address indexed arbitration, uint256 indexed taskId, uint8 round, bool majority, bytes32 result);
    event CageRuled(address indexed arbitration, uint256 indexed taskId, uint8 outcome, uint16 workerBps, uint8 round);
    event Seated(uint256 pfand, uint256 microBond, uint256 standardBond);
    event Unseated(uint256 refunded);
    event BondWithdrawn(address indexed vault, uint256 amount);

    error Phase_();
    error Auth();
    error Allocation();
    error Commitment();
    error TooLate();
    error Init();
    error Module();
    error StillSeated();
    error Evidence_();

    constructor(
        address config_,
        address nearConfig_,
        address verifier_,
        address pool_,
        address factory_,
        address panelOwner_,
        address microScope_,
        address standardScope_
    ) {
        config = BotledConfig(config_);
        nearConfig = INearConfig(nearConfig_);
        verifier = INearVerifier(verifier_);
        if (verifier.nearConfig() != nearConfig_) revert Init();
        pool = BotledRunnerPoolNear(payable(pool_));
        bondToken = BotledRunnerPoolNear(payable(pool_)).rewardToken();
        factory = factory_;
        panelOwner = IBotledPanelOwnerSeatN(panelOwner_);
        micro = IAzzleArbitrationV2(IBotledPanelOwnerSeatN(panelOwner_).micro());
        standard = IAzzleArbitrationV2(IBotledPanelOwnerSeatN(panelOwner_).standard());
        microVault = IAzzleBondVaultV2(micro.bonds());
        standardVault = IAzzleBondVaultV2(standard.bonds());
        azl = IERC20(microVault.azl());
        if (address(micro) == address(standard) || standardVault.azl() != address(azl)) revert Init();
        microScope = IAzzleTaskScope(microScope_);
        standardScope = IAzzleTaskScope(standardScope_);
        operator = address(1); // lock the implementation
    }

    function initialize(uint32 constitutionId_, address operator_) external {
        if (msg.sender != factory || operator != address(0) || operator_ == address(0)) revert Init();
        constitutionId = constitutionId_;
        laneCount = uint8(nearConfig.laneCount(constitutionId_));
        operator = operator_;
    }

    modifier onlyOperator() { if (msg.sender != operator) revert Auth(); _; }

    /// @dev Pfand refunds from BotledPanelOwner (pushed with a 50k gas stipend) land here.
    receive() external payable {}

    // ================================================================ operator: seat only

    /// @notice Bonds up to `target` (at least minimumBond + reserved slashes) in one vault, pulling AZL from
    ///         the operator. Also cancels a scheduled withdrawal (bonding resets it in the vault).
    function topUpBond(uint8 m, uint256 target) public onlyOperator nonReentrant {
        CageSeat.topUp(_vault(m), azl, operator, target);
    }

    /// @notice One call from zero to a seat on both panels: bond `microTarget` / `standardTarget`
    ///         (each raised to the vault minimum), then BotledPanelOwner.join{value: pfand}() as this cage.
    ///         Needs AZL allowance operator -> cage for the missing amount (11,000 AZL for a fresh cage).
    function seat(uint256 microTarget, uint256 standardTarget) external payable onlyOperator nonReentrant {
        CageSeat.seat(microVault, standardVault, azl, operator, panelOwner, microTarget, standardTarget, msg.value);
    }

    /// @notice Leaves both panels (BotledPanelOwner reverts while an Azzle dispute is assigned) and forwards
    ///         the refunded pfand to the operator. Botled cases already opened keep running to their end.
    function unseat() public onlyOperator nonReentrant {
        CageSeat.unseat(panelOwner, operator);
    }

    /// @notice Pulls a pfand whose push transfer failed (BotledPanelOwner.claimable) and forwards it.
    function claimPfand() external onlyOperator nonReentrant {
        CageSeat.claimPfand(panelOwner, operator);
    }

    /// @notice Starts the Azzle withdrawal cooldown in both vaults. Refuses while seated.
    function scheduleExit() public onlyOperator {
        if (!CageSeat.scheduleExit(panelOwner, microVault, standardVault)) revert StillSeated();
    }

    /// @notice unseat() + scheduleExit() in one transaction.
    function exit() external onlyOperator {
        unseat();
        scheduleExit();
    }

    /// @notice After the vault cooldown: withdraw `amount` (0 = everything) from vault `m` to the operator.
    function withdrawBond(uint8 m, uint256 amount) external onlyOperator nonReentrant {
        CageSeat.withdrawBond(_vault(m), azl, operator, amount);
    }

    // ================================================================ open

    /// @notice Permissionless once Azzle's evidence window closed. Any ETH sent tops up the pool's VRF fund.
    function openCase(address arbitration, uint256 taskId) external payable nonReentrant {
        IAzzleArbitrationV2 arb = _module(arbitration);
        if (taskId == 0 || taskId > MAX_TASK_ID) revert Phase_();
        bytes32 k = caseKey(arbitration, taskId);
        Case storage c = cases[k];
        if (c.phase != Phase.NONE) revert Phase_();
        (, , address a, bytes32 posterEv, bytes32 workerEv, uint64 evidenceDeadline, , uint8 status, ,) = arb.disputes(taskId);
        if (a != address(this) || block.timestamp <= evidenceDeadline) revert Phase_();
        if (status == ST_EVIDENCE) arb.beginRuling(taskId);
        (, , , , , , uint64 rulingDeadline, uint8 s2, ,) = arb.disputes(taskId);
        if (s2 != ST_RULING) revert Phase_();
        _fundVrf();

        (c.poster, c.worker) = IAzzleTaskParties(arb.registry()).taskParties(taskId);
        uint32 pid = config.currentParamsId();
        BotledConfig.Params memory p = config.getParams(pid);
        c.paramsId = pid;
        c.hardStop = rulingDeadline > p.safetyMargin ? rulingDeadline - p.safetyMargin : 0;
        bytes32 scopeHash;
        (c.inputHash, scopeHash) = _inputHash(arbitration, taskId, c.poster, c.worker, posterEv, workerEv);
        evidence[k] = Evidence(posterEv, workerEv, scopeHash, 0, 0, 0);
        emit CaseOpened(arbitration, taskId, constitutionId, pid, c.inputHash, c.hardStop);
        if (!_roundFits(c, p)) revert TooLate(); // nothing fits any more: Azzle timeout applies
        _startRound(arbitration, taskId, 1, address(0), 0, p);
    }

    /// @notice If the pool could not pay VRF when the round started, anyone may retry after topping it up.
    function retryDraw(address arbitration, uint256 taskId) external payable nonReentrant {
        bytes32 k = caseKey(arbitration, taskId);
        Case storage c = cases[k];
        if (c.phase != Phase.JURY) revert Phase_();
        uint256 id = _drawId(arbitration, taskId, c.round);
        (uint64 requestedAt,,,) = pool.drawInfo(address(this), id);
        BotledConfig.Params memory p = config.getParams(c.paramsId);
        if (requestedAt != 0) revert Phase_();
        if (!_roundFits(c, p)) revert TooLate();
        _fundVrf();
        c.deadline = _min(block.timestamp + p.vrfTimeout, c.hardStop);
        if (!pool.requestDraw(id, c.poster, c.worker, p.jurySizes[c.round - 1], c.deadline)) revert Phase_();
    }

    // ================================================================ appeal / jury

    function appealBond(address arbitration, uint256 taskId, uint8 round) public view returns (uint256) {
        if (round < 2 || round > FINAL_ROUND) return 0;
        return config.getParams(cases[caseKey(arbitration, taskId)].paramsId).appealBonds[round - 2];
    }

    /// @notice Poster or worker escalates the standing result to the next (larger) jury.
    function appeal(address arbitration, uint256 taskId) external payable nonReentrant {
        bytes32 k = caseKey(arbitration, taskId);
        Case storage c = cases[k];
        if (c.phase != Phase.APPEAL || block.timestamp > c.deadline || !c.hasResult) revert Phase_();
        if (msg.sender != c.poster && msg.sender != c.worker) revert Auth();
        uint8 r = c.round + 1;
        BotledConfig.Params memory p = config.getParams(c.paramsId);
        if (r > FINAL_ROUND || !_roundFits(c, p)) revert TooLate();
        uint128 bond = p.appealBonds[r - 2];
        if (bond > 0) bondToken.safeTransferFrom(msg.sender, address(this), bond);
        heldBonds += bond;
        _fundVrf();
        _startRound(arbitration, taskId, r, msg.sender, bond, p);
    }

    // ================================================================ evidence binding

    /// @notice Permissionless, once per case: publishes the raw documents behind Azzle's evidence hashes and binds
    ///         the escaped USER(case) request piece. keccak256(posterDoc) must equal the poster evidence hash (empty
    ///         document for a zero hash), same for the worker; keccak256(scope) must equal the on-chain scope hash.
    ///         The first drawn runner usually calls this right after the draw (one tx, a few cents on Base).
    function bindEvidence(address arbitration, uint256 taskId, bytes calldata scope, bytes calldata posterDoc, bytes calldata workerDoc)
        external
    {
        bytes32 k = caseKey(arbitration, taskId);
        Case storage c = cases[k];
        Evidence storage e = evidence[k];
        if (c.phase == Phase.NONE || c.phase == Phase.RULED || e.userHash != 0) revert Phase_();
        (bytes32 h, uint32 len) = verifier.userBindingChecked(scope, posterDoc, workerDoc, e.scopeHash, e.posterEv, e.workerEv);
        e.userHash = h;
        e.userLen = len;
        e.boundAt = uint64(block.timestamp);
        emit EvidenceBound(arbitration, taskId, h, len);
    }

    // ================================================================ jury

    /// @dev commitment = keccak256(abi.encode(cage, arbitration, taskId, round, runner, inputHash, outcome, workerBps, salt))
    function commit(address arbitration, uint256 taskId, bytes32 commitment) external {
        _commit(arbitration, taskId, msg.sender, commitment);
    }

    /// @notice Relayed commit: `sig` is an EIP-712 signature over Commit(arbitration, taskId, round, commitment) by the
    ///         runner's Chain Signatures address or by the session key of its current enrollment ticket.
    function commitFor(address arbitration, uint256 taskId, address runner, bytes32 commitment, bytes calldata sig) external {
        uint8 r = cases[caseKey(arbitration, taskId)].round;
        address s = verifier.commitSigner(address(this), arbitration, taskId, r, commitment, sig);
        if (s == address(0) || (s != runner && s != pool.sessionKeyOf(runner))) revert Auth();
        _commit(arbitration, taskId, runner, commitment);
    }

    function _commit(address arbitration, uint256 taskId, address runner, bytes32 commitment) internal {
        bytes32 k = caseKey(arbitration, taskId);
        Case storage c = cases[k];
        uint8 r = c.round;
        (uint256 commitEnd,) = _windows(arbitration, taskId, c);
        if (c.phase != Phase.JURY || commitEnd == 0 || block.timestamp > commitEnd) revert Phase_();
        if (
            pool.seat(address(this), _drawId(arbitration, taskId, r), runner) == 0 || commitments[k][r][runner] != 0
                || commitment == 0
        ) revert Auth();
        commitments[k][r][runner] = commitment;
        emit Committed(arbitration, taskId, r, runner);
    }

    /// @notice Permissionless submitter: the commitment binds the runner, the receipt binds runner + round + case.
    ///         The seat's model lane is fixed by the VRF draw order: lane = (seat - 1) % laneCount. A receipt co-signed
    ///         by a sponsor relay is a counted vote; one without (runner's own NEAR AI key) only proves liveness.
    function reveal(
        address arbitration,
        uint256 taskId,
        address runner,
        uint8 outcome,
        uint16 workerBps,
        bytes32 salt,
        INearVerifier.Receipt calldata rc
    ) external {
        bytes32 k = caseKey(arbitration, taskId);
        Case storage c = cases[k];
        (uint256 commitEnd, uint256 revealEnd) = _windows(arbitration, taskId, c);
        if (c.phase != Phase.JURY || block.timestamp <= commitEnd || block.timestamp > revealEnd) revert Phase_();
        uint8 r = c.round;
        if (votes[k][r][runner] != 0) revert Commitment();
        bytes32 expected =
            keccak256(abi.encode(address(this), arbitration, taskId, r, runner, c.inputHash, outcome, workerBps, salt));
        if (commitments[k][r][runner] != expected) revert Commitment();
        CageVotes.validate(outcome, workerBps);
        uint8 lane = (pool.seat(address(this), _drawId(arbitration, taskId, r), runner) - 1) % laneCount;
        (bytes32 reqHash, bytes32 respHash, bool counted) = _checkReceipt(k, c, r, runner, outcome, workerBps, lane, rc);

        CageSettle.Round storage rd = rounds[k][r];
        rd.revealed++;
        if (counted) {
            bytes32 vote = keccak256(abi.encode(outcome, workerBps));
            votes[k][r][runner] = vote;
            Tally storage t = tallies[k][r][vote];
            t.count++;
            t.laneMask |= uint8(1 << lane);
            if (t.count > rd.leaderCount) { rd.leaderCount = t.count; rd.leaderVote = vote; }
        } else {
            votes[k][r][runner] = LIVENESS;
        }
        emit Revealed(arbitration, taskId, r, runner, outcome, workerBps, lane, reqHash, respHash, rc.signerId, counted ? rc.sponsorId : 0, counted);
    }

    function _checkReceipt(
        bytes32 k,
        Case storage c,
        uint8 r,
        address runner,
        uint8 outcome,
        uint16 workerBps,
        uint8 lane,
        INearVerifier.Receipt calldata rc
    ) internal view returns (bytes32 reqHash, bytes32 respHash, bool counted) {
        Evidence storage e = evidence[k];
        if (e.userHash == 0) revert Evidence_();
        INearVerifier.Ctx memory ctx =
            INearVerifier.Ctx(constitutionId, lane, runner, r, c.inputHash, e.userHash, e.userLen);
        uint8 o;
        uint16 b;
        (o, b, reqHash, respHash, counted) = verifier.check(ctx, rc);
        if (o != outcome || b != workerBps) revert Commitment(); // the signed answer must be the revealed vote
    }

    /// @notice Permissionless. Early once every drawn runner revealed; otherwise after the reveal window / VRF timeout.
    function closeRound(address arbitration, uint256 taskId) external nonReentrant {
        bytes32 k = caseKey(arbitration, taskId);
        Case storage c = cases[k];
        if (c.phase != Phase.JURY) revert Phase_();
        uint8 r = c.round;
        (, uint64 fulfilledAt, uint256 drawnCount,) = pool.drawInfo(address(this), _drawId(arbitration, taskId, r));
        if (fulfilledAt == 0) {
            if (block.timestamp <= c.deadline) revert Phase_(); // VRF still pending
        } else {
            (, uint256 revealEnd) = _windows(arbitration, taskId, c);
            if (block.timestamp <= revealEnd && rounds[k][r].revealed < drawnCount) revert Phase_();
        }
        BotledConfig.Params memory p = config.getParams(c.paramsId);
        CageSettle.Round storage rd = rounds[k][r];
        bool majority = uint256(rd.leaderCount) * 2 > p.jurySizes[r - 1] && _outcomeOf(rd.leaderVote) != NONE_
            && _popcount(tallies[k][r][rd.leaderVote].laneMask) >= p.minProviders;
        if (majority) {
            c.result = rd.leaderVote;
            c.hasResult = true;
        }
        emit RoundClosed(arbitration, taskId, r, majority, c.result);

        if (r == FINAL_ROUND) {
            if (c.hasResult) return _execute(arbitration, taskId);
            c.phase = Phase.APPEAL; // nothing decidable: Azzle timeout applies, then syncAzzleTimeout
            c.deadline = c.hardStop;
            return;
        }
        if (!c.hasResult) {
            if (_roundFits(c, p)) return _startRound(arbitration, taskId, r + 1, address(0), 0, p);
            c.phase = Phase.APPEAL;
            c.deadline = c.hardStop;
            return;
        }
        c.phase = Phase.APPEAL;
        c.deadline = _appealDeadline(c, p);
    }

    /// @notice Executes the standing result once the appeal window passed unappealed.
    function finalize(address arbitration, uint256 taskId) external nonReentrant {
        Case storage c = cases[caseKey(arbitration, taskId)];
        if (c.phase != Phase.APPEAL || block.timestamp <= c.deadline || !c.hasResult) revert Phase_();
        _execute(arbitration, taskId);
    }

    /// @notice Cleanup after Azzle's own `timeout` settled a dispute the cage could not rule.
    function syncAzzleTimeout(address arbitration, uint256 taskId) external nonReentrant {
        bytes32 k = caseKey(arbitration, taskId);
        Case storage c = cases[k];
        if (c.phase == Phase.NONE || c.phase == Phase.RULED) revert Phase_();
        (, , , , , , , uint8 s, ,) = _module(arbitration).disputes(taskId);
        if (s != ST_SETTLED) revert Phase_();
        c.phase = Phase.RULED;
        BotledConfig.Params memory p = config.getParams(c.paramsId);
        heldBonds -= CageSettle.refundAll(rounds[k], bondToken, c.round);
        for (uint8 r = 1; r <= c.round; ++r) _settleDraw(arbitration, taskId, r, 0, 0, p);
    }

    // ================================================================ internals

    function _startRound(address arbitration, uint256 taskId, uint8 r, address appellant, uint128 bond, BotledConfig.Params memory p)
        internal
    {
        bytes32 k = caseKey(arbitration, taskId);
        Case storage c = cases[k];
        CageSettle.Round storage rd = rounds[k][r];
        rd.appellant = appellant;
        rd.appealedResult = c.result;
        rd.bond = bond;
        c.round = r;
        c.phase = Phase.JURY;
        c.deadline = _min(block.timestamp + p.vrfTimeout, c.hardStop);
        uint8 n = p.jurySizes[r - 1];
        bool ok = pool.requestDraw(_drawId(arbitration, taskId, r), c.poster, c.worker, n, c.deadline);
        emit RoundStarted(arbitration, taskId, r, n, appellant, bond, ok);
    }

    function _execute(address arbitration, uint256 taskId) internal {
        bytes32 k = caseKey(arbitration, taskId);
        Case storage c = cases[k];
        c.phase = Phase.RULED;
        (uint8 o, uint16 bps) = CageVotes.decode(c.result);
        _module(arbitration).rule(taskId, o, bps); // routed to the module that assigned the task
        emit CageRuled(arbitration, taskId, o, bps, c.round);

        (uint256 bonus, uint256 released) =
            CageSettle.settleAppealBonds(rounds[k], bondToken, address(pool), c.round, c.result, c.poster, c.worker);
        heldBonds -= released;
        BotledConfig.Params memory p = config.getParams(c.paramsId);
        for (uint8 r = 1; r <= c.round; ++r) _settleDraw(arbitration, taskId, r, c.result, r == c.round ? bonus : 0, p);
    }

    function _settleDraw(address arbitration, uint256 taskId, uint8 r, bytes32 finalVote, uint256 bonus, BotledConfig.Params memory p)
        internal
    {
        bytes32 k = caseKey(arbitration, taskId);
        CageSettle.settleDraw(
            votes[k][r], IDrawSink(address(pool)), _drawId(arbitration, taskId, r), evidence[k].boundAt, p.commitWindow,
            finalVote == 0 ? 0 : uint256(p.rewardPerRound) + bonus
        );
    }

    function _fundVrf() internal {
        if (msg.value == 0) return;
        (bool ok,) = address(pool).call{value: msg.value}("");
        require(ok, "BL: vrf");
    }

    function _module(address arbitration) internal view returns (IAzzleArbitrationV2) {
        if (arbitration != address(micro) && arbitration != address(standard)) revert Module();
        return IAzzleArbitrationV2(arbitration);
    }

    function _vault(uint8 m) internal view returns (IAzzleBondVaultV2) {
        if (m > 1) revert Module();
        return m == 0 ? microVault : standardVault;
    }

    function _roundLen(BotledConfig.Params memory p) internal pure returns (uint256) {
        return uint256(p.vrfTimeout) + p.commitWindow + p.revealWindow;
    }

    function _roundFits(Case storage c, BotledConfig.Params memory p) internal view returns (bool) {
        return block.timestamp + _roundLen(p) <= c.hardStop;
    }

    function _appealDeadline(Case storage c, BotledConfig.Params memory p) internal view returns (uint64) {
        uint256 roundLen = _roundLen(p);
        uint256 latest = c.hardStop > roundLen ? c.hardStop - roundLen : 0;
        uint256 end = block.timestamp + p.appealWindow;
        if (end > latest) end = latest > block.timestamp ? latest : block.timestamp;
        return uint64(end);
    }

    function _windows(address arbitration, uint256 taskId, Case storage c) internal view returns (uint256 commitEnd, uint256 revealEnd) {
        if (c.phase == Phase.NONE) return (0, 0);
        (, uint64 f,,) = pool.drawInfo(address(this), _drawId(arbitration, taskId, c.round));
        if (f == 0) return (0, 0);
        BotledConfig.Params memory p = config.getParams(c.paramsId);
        revealEnd = _min(uint256(f) + p.commitWindow + p.revealWindow, c.hardStop);
        commitEnd = _min(uint256(f) + p.commitWindow, revealEnd);
    }

    // ================================================================ views

    function caseKey(address arbitration, uint256 taskId) public pure returns (bytes32) {
        return keccak256(abi.encode(arbitration, taskId));
    }

    function getCase(address arbitration, uint256 taskId) external view returns (Case memory) {
        return cases[caseKey(arbitration, taskId)];
    }

    /// @notice (commitEnd, revealEnd) of the current round; (0, 0) while the draw is pending.
    function windows(address arbitration, uint256 taskId) external view returns (uint256, uint256) {
        return _windows(arbitration, taskId, cases[caseKey(arbitration, taskId)]);
    }

    /// @notice Pool draw id: bits 248.. = module index + 1 (1 micro, 2 standard), 8..247 = taskId, 0..7 = round.
    function drawId(address arbitration, uint256 taskId, uint8 r) external view returns (uint256) {
        return _drawId(arbitration, taskId, r);
    }

    function _drawId(address arbitration, uint256 taskId, uint8 r) internal view returns (uint256) {
        uint256 m = arbitration == address(micro) ? 1 : arbitration == address(standard) ? 2 : 0;
        if (m == 0) revert Module();
        return (m << 248) | (taskId << 8) | r;
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint64) { return uint64(a < b ? a : b); }

    function _popcount(uint8 x) internal pure returns (uint8 n) {
        for (; x != 0; x &= x - 1) ++n;
    }

    function _inputHash(address arbitration, uint256 taskId, address poster, address worker, bytes32 posterEv, bytes32 workerEv)
        internal
        view
        returns (bytes32 h, bytes32 scopeHash)
    {
        IAzzleTaskScope s = arbitration == address(micro) ? microScope : standardScope;
        scopeHash = address(s) == address(0) ? bytes32(0) : keccak256(bytes(s.scopeOf(taskId)));
        h = keccak256(
            abi.encode(
                DOMAIN, block.chainid, arbitration, taskId, nearConfig.templateHash(constitutionId), scopeHash, poster, worker,
                posterEv, workerEv
            )
        );
    }

    function _outcomeOf(bytes32 v) internal pure returns (uint8 o) { (o,) = CageVotes.decode(v); }
}
