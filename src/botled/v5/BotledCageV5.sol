// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {
    IAzzleArbitrationV2, IAzzleTaskParties, IAzzleBondVaultV2, IAzzleTaskScope
} from "../interfaces/IAzzle.sol";
import {BotledConfig} from "../BotledConfig.sol";
import {BotledRunnerPool} from "../BotledRunnerPool.sol";

/// @dev Seat surface of the deployed BotledPanelOwner (0xF7E5…7a04 on Base).
interface IBotledPanelOwnerSeat {
    function micro() external view returns (address);
    function standard() external view returns (address);
    function pfand() external view returns (uint256);
    function isSeated(address m) external view returns (bool);
    function join() external payable;
    function leave() external;
    function claim() external;
    function claimable(address m) external view returns (uint256);
}

/// @title Botled v5 cage — one self-serve arbitrator seat on BOTH Azzle panels (micro + standard)
/// @notice EIP-1167 clone, no admin, no upgrade, no guardian. Same jury mechanics as v4 (VRF juries from a
///         global BotledRunnerPool, commit -> reveal, absolute majority + lane diversity, bonded appeals
///         3 -> 7 -> 15, slashing of no-shows and minority votes, everything clipped before Azzle's
///         rulingDeadline). New in v5:
///           * the operator seats the cage permissionlessly through BotledPanelOwner.join(): the cage bonds
///             in BOTH Azzle vaults from its own address and calls join{value: pfand} as msg.sender;
///           * a case is (arbitration module, taskId): micro and standard have separate task registries,
///             so task ids collide; every function takes the module address and only the two modules the
///             PanelOwner manages are accepted (a fake module can never trigger draws or slashes);
///           * leave / scheduleExit / withdraw return the pfand and both bonds to the operator.
///         The operator has no power over cases: it can only fund, seat and unseat the cage.
contract BotledCageV5 is ReentrancyGuard {
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
    uint8 public constant VERSION = 5;
    uint16 public constant SPLIT_STEP_BPS = 500;
    uint16 public constant NEUTRAL_BAND_BPS = 1_000;
    uint256 internal constant MAX_TASK_ID = (1 << 240) - 1;
    bytes32 public constant DOMAIN = keccak256("BOTLED.v5");

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
        uint8 laneMask;
    }

    // ------------------------------------------------ shared by all clones (implementation code)
    BotledConfig public immutable config;
    BotledRunnerPool public immutable pool;
    IERC20 public immutable bondToken;      // runner + appeal bonds (pool token)
    address public immutable factory;
    IBotledPanelOwnerSeat public immutable panelOwner;
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
    mapping(bytes32 => mapping(uint8 => Round)) public rounds;
    mapping(bytes32 => mapping(uint8 => mapping(address => bytes32))) public commitments;
    mapping(bytes32 => mapping(uint8 => mapping(address => bytes32))) public votes;
    mapping(bytes32 => mapping(uint8 => mapping(bytes32 => Tally))) public tallies;
    uint256 public heldBonds;

    event CaseOpened(address indexed arbitration, uint256 indexed taskId, uint32 constitutionId, uint32 paramsId, bytes32 inputHash, uint64 hardStop);
    event RoundStarted(address indexed arbitration, uint256 indexed taskId, uint8 round, uint8 jurors, address appellant, uint256 bond, bool drawRequested);
    event Committed(address indexed arbitration, uint256 indexed taskId, uint8 round, address indexed runner);
    event Revealed(
        address indexed arbitration, uint256 indexed taskId, uint8 round, address indexed runner, uint8 outcome, uint16 workerBps,
        uint8 lane, bytes32 transcriptHash
    );
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

    constructor(
        address config_,
        address pool_,
        address factory_,
        address panelOwner_,
        address microScope_,
        address standardScope_
    ) {
        config = BotledConfig(config_);
        pool = BotledRunnerPool(payable(pool_));
        bondToken = BotledRunnerPool(payable(pool_)).bondToken();
        factory = factory_;
        panelOwner = IBotledPanelOwnerSeat(panelOwner_);
        micro = IAzzleArbitrationV2(IBotledPanelOwnerSeat(panelOwner_).micro());
        standard = IAzzleArbitrationV2(IBotledPanelOwnerSeat(panelOwner_).standard());
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
        laneCount = uint8(config.laneCount(constitutionId_));
        operator = operator_;
    }

    modifier onlyOperator() { if (msg.sender != operator) revert Auth(); _; }

    /// @dev Pfand refunds from BotledPanelOwner (pushed with a 50k gas stipend) land here.
    receive() external payable {}

    // ================================================================ operator: seat only

    /// @notice Bonds up to `target` (at least minimumBond + reserved slashes) in one vault, pulling AZL from
    ///         the operator. Also cancels a scheduled withdrawal (bonding resets it in the vault).
    function topUpBond(uint8 m, uint256 target) public onlyOperator nonReentrant {
        _topUp(_vault(m), target);
    }

    /// @notice One call from zero to a seat on both panels: bond `microTarget` / `standardTarget`
    ///         (each raised to the vault minimum), then BotledPanelOwner.join{value: pfand}() as this cage.
    ///         Needs AZL allowance operator -> cage for the missing amount (11,000 AZL for a fresh cage).
    function seat(uint256 microTarget, uint256 standardTarget) external payable onlyOperator nonReentrant {
        _topUp(microVault, microTarget);
        _topUp(standardVault, standardTarget);
        panelOwner.join{value: msg.value}();
        emit Seated(msg.value, microVault.bonds(address(this)), standardVault.bonds(address(this)));
    }

    /// @notice Leaves both panels (BotledPanelOwner reverts while an Azzle dispute is assigned) and forwards
    ///         the refunded pfand to the operator. Botled cases already opened keep running to their end.
    function unseat() public onlyOperator nonReentrant {
        panelOwner.leave();
        uint256 bal = address(this).balance;
        _sendEth(operator, bal);
        emit Unseated(bal);
    }

    /// @notice Pulls a pfand whose push transfer failed (BotledPanelOwner.claimable) and forwards it.
    function claimPfand() external onlyOperator nonReentrant {
        if (panelOwner.claimable(address(this)) > 0) panelOwner.claim();
        _sendEth(operator, address(this).balance);
    }

    /// @notice Starts the Azzle withdrawal cooldown in both vaults. Refuses while seated, because a seated
    ///         cage that is not eligible can be kicked by anyone and would forfeit its pfand.
    function scheduleExit() public onlyOperator {
        if (panelOwner.isSeated(address(this))) revert StillSeated();
        if (microVault.bonds(address(this)) > 0) microVault.scheduleWithdrawal();
        if (standardVault.bonds(address(this)) > 0) standardVault.scheduleWithdrawal();
    }

    /// @notice unseat() + scheduleExit() in one transaction.
    function exit() external onlyOperator {
        unseat();
        scheduleExit();
    }

    /// @notice After the vault cooldown: withdraw `amount` (0 = everything) from vault `m` to the operator.
    function withdrawBond(uint8 m, uint256 amount) external onlyOperator nonReentrant {
        IAzzleBondVaultV2 v = _vault(m);
        if (amount == 0) amount = v.bonds(address(this));
        uint256 before = azl.balanceOf(address(this));
        v.withdraw(amount);
        uint256 got = azl.balanceOf(address(this)) - before;
        azl.safeTransfer(operator, got); // exactly what left the vault: held appeal bonds are never touched
        emit BondWithdrawn(address(v), got);
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
        c.inputHash = _inputHash(arbitration, taskId, c.poster, c.worker, posterEv, workerEv);
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

    /// @dev commitment = keccak256(abi.encode(cage, arbitration, taskId, round, runner, inputHash, outcome,
    ///      workerBps, lane, transcriptHash, salt))
    function commit(address arbitration, uint256 taskId, bytes32 commitment) external {
        bytes32 k = caseKey(arbitration, taskId);
        Case storage c = cases[k];
        uint8 r = c.round;
        (uint256 commitEnd,) = _windows(arbitration, taskId, c);
        if (c.phase != Phase.JURY || commitEnd == 0 || block.timestamp > commitEnd) revert Phase_();
        if (
            !pool.isDrawn(address(this), _drawId(arbitration, taskId, r), msg.sender) || commitments[k][r][msg.sender] != 0
                || commitment == 0
        ) revert Auth();
        commitments[k][r][msg.sender] = commitment;
        emit Committed(arbitration, taskId, r, msg.sender);
    }

    function reveal(
        address arbitration,
        uint256 taskId,
        uint8 outcome,
        uint16 workerBps,
        uint8 lane,
        bytes32 transcriptHash,
        bytes32 salt
    ) external {
        bytes32 k = caseKey(arbitration, taskId);
        Case storage c = cases[k];
        (uint256 commitEnd, uint256 revealEnd) = _windows(arbitration, taskId, c);
        if (c.phase != Phase.JURY || block.timestamp <= commitEnd || block.timestamp > revealEnd) revert Phase_();
        uint8 r = c.round;
        if (votes[k][r][msg.sender] != 0) revert Commitment();
        bytes32 expected = keccak256(
            abi.encode(
                address(this), arbitration, taskId, r, msg.sender, c.inputHash, outcome, workerBps, lane, transcriptHash, salt
            )
        );
        if (commitments[k][r][msg.sender] != expected || lane >= laneCount) revert Commitment();
        _validate(outcome, workerBps);
        bytes32 vote = keccak256(abi.encode(outcome, workerBps));
        votes[k][r][msg.sender] = vote;
        Tally storage t = tallies[k][r][vote];
        t.count++;
        t.laneMask |= uint8(1 << lane);
        Round storage rd = rounds[k][r];
        rd.revealed++;
        if (t.count > rd.leaderCount) { rd.leaderCount = t.count; rd.leaderVote = vote; }
        emit Revealed(arbitration, taskId, r, msg.sender, outcome, workerBps, lane, transcriptHash);
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
        Round storage rd = rounds[k][r];
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
        for (uint8 r = 1; r <= c.round; ++r) {
            Round storage rd = rounds[k][r];
            if (rd.bond > 0) { heldBonds -= rd.bond; bondToken.safeTransfer(rd.appellant, rd.bond); }
            _settleDraw(arbitration, taskId, r, 0, 0, p);
        }
    }

    // ================================================================ internals

    function _startRound(address arbitration, uint256 taskId, uint8 r, address appellant, uint128 bond, BotledConfig.Params memory p)
        internal
    {
        bytes32 k = caseKey(arbitration, taskId);
        Case storage c = cases[k];
        Round storage rd = rounds[k][r];
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
        (uint8 o, uint16 bps) = _decode(c.result);
        _module(arbitration).rule(taskId, o, bps); // routed to the module that assigned the task
        emit CageRuled(arbitration, taskId, o, bps, c.round);

        uint256 bonus;
        for (uint8 r = 2; r <= c.round; ++r) {
            Round storage rd = rounds[k][r];
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
        for (uint8 r = 1; r <= c.round; ++r) _settleDraw(arbitration, taskId, r, c.result, r == c.round ? bonus : 0, p);
    }

    function _settleDraw(address arbitration, uint256 taskId, uint8 r, bytes32 finalVote, uint256 bonus, BotledConfig.Params memory p)
        internal
    {
        uint256 id = _drawId(arbitration, taskId, r);
        (uint64 requestedAt,,, bool settled) = pool.drawInfo(address(this), id);
        if (requestedAt == 0 || settled) return;
        bytes32 k = caseKey(arbitration, taskId);
        address[] memory list = pool.drawnRunners(address(this), id);
        uint256[] memory slashes = new uint256[](list.length);
        bool[] memory rewarded = new bool[](list.length);
        for (uint256 i; i < list.length; ++i) {
            bytes32 v = votes[k][r][list[i]];
            if (v == 0) slashes[i] = p.noShowSlash;
            else if (finalVote != 0 && v != finalVote) slashes[i] = p.minoritySlash;
            rewarded[i] = finalVote != 0 && v == finalVote;
        }
        pool.settleDraw(id, slashes, rewarded, finalVote == 0 ? 0 : uint256(p.rewardPerRound) + bonus);
    }

    function _topUp(IAzzleBondVaultV2 v, uint256 target) internal {
        uint256 have = v.bonds(address(this));
        uint256 need = v.reservedSlash(address(this)) + v.assignmentReserve();
        uint256 min = v.minimumBond();
        if (target < need) target = need;
        if (target < min) target = min;
        uint256 add = target > have ? target - have : (v.withdrawReadyAt(address(this)) != 0 ? 1 : 0);
        if (add == 0) return;
        azl.safeTransferFrom(operator, address(this), add);
        azl.forceApprove(address(v), add);
        v.bond(add);
    }

    function _sendEth(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        require(ok, "BL: eth");
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

    function getRound(address arbitration, uint256 taskId, uint8 r) external view returns (Round memory) {
        return rounds[caseKey(arbitration, taskId)][r];
    }

    function commitmentOf(address arbitration, uint256 taskId, uint8 r, address runner) external view returns (bytes32) {
        return commitments[caseKey(arbitration, taskId)][r][runner];
    }

    function voteOf(address arbitration, uint256 taskId, uint8 r, address runner) external view returns (bytes32) {
        return votes[caseKey(arbitration, taskId)][r][runner];
    }

    /// @notice (commitEnd, revealEnd) of the current round; (0, 0) while the draw is pending.
    function windows(address arbitration, uint256 taskId) external view returns (uint256, uint256) {
        return _windows(arbitration, taskId, cases[caseKey(arbitration, taskId)]);
    }

    /// @notice Pool draw id: bits 248.. = module index + 1 (1 micro, 2 standard), 8..247 = taskId, 0..7 = round.
    function drawId(address arbitration, uint256 taskId, uint8 r) external view returns (uint256) {
        return _drawId(arbitration, taskId, r);
    }

    /// @notice Inverse of drawId (for runners that discover draws from pool events).
    function decodeDrawId(uint256 id) public view returns (address arbitration, uint256 taskId, uint8 r) {
        uint256 m = id >> 248;
        if (m == 0 || m > 2) revert Module();
        arbitration = m == 1 ? address(micro) : address(standard);
        taskId = (id >> 8) & MAX_TASK_ID;
        r = uint8(id);
    }

    /// @notice Seat status across both panels.
    function seatStatus()
        external
        view
        returns (bool seated, bool microEligible, bool standardEligible, uint256 microBond, uint256 standardBond)
    {
        seated = panelOwner.isSeated(address(this));
        microEligible = microVault.isEligible(address(this));
        standardEligible = standardVault.isEligible(address(this));
        microBond = microVault.bonds(address(this));
        standardBond = standardVault.bonds(address(this));
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
        returns (bytes32)
    {
        IAzzleTaskScope s = arbitration == address(micro) ? microScope : standardScope;
        bytes32 scopeHash = address(s) == address(0) ? bytes32(0) : keccak256(bytes(s.scopeOf(taskId)));
        return keccak256(
            abi.encode(
                DOMAIN, block.chainid, arbitration, taskId, config.constitutionHash(constitutionId), scopeHash, poster, worker,
                posterEv, workerEv
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
