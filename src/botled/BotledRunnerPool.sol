// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {NativeVrfConsumer} from "../shared/NativeVrfConsumer.sol";

interface IBotledFactoryView {
    function isCage(address cage) external view returns (bool);
}

interface IBotledConfigView {
    function factory() external view returns (address);
}

/// @title Botled v4 — global runner pool (the jury)
/// @notice Runners bond the bond token once (AZL on Base, configurable at deploy). Each jury round draws
///         n runners with Chainlink VRF v2.5 (native ETH, direct funding, paid from this contract's ETH).
///         A cage cannot choose, add or exclude runners: it can only ask for a draw and report votes.
///         Slashes of a draw go to the coherent runners of that same draw (else to the reward fund).
/// @dev No owner. Only factory-born cages (config.factory().isCage) may request draws or settle.
contract BotledRunnerPool is NativeVrfConsumer, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Runner {
        bool listed;
        uint32 activeCases;
        uint64 exitReadyAt;
        uint256 bond;
    }

    struct Draw {
        address cage;
        uint8 n;
        bool settled;
        uint64 requestedAt;
        uint64 fulfillBy;   // late VRF answers are ignored (nobody gets drawn for a closed round)
        uint64 fulfilledAt;
        address poster;
        address worker;
    }

    uint256 public constant MAX_RUNNERS = 128;
    uint32 public constant MAX_CALLBACK_GAS = 2_400_000; // coordinator maxGasLimit 2.5M minus wrapper overhead

    address public immutable config;
    IERC20 public immutable bondToken;
    uint256 public immutable runnerReserve;   // locked per runner per active draw (caps any single slash)
    uint64 public immutable exitCooldown;
    uint32 public immutable callbackGasBase;
    uint32 public immutable callbackGasPerJuror;
    uint16 public immutable requestConfirmations;

    address[] public runnerList;
    mapping(address => Runner) public runners;
    mapping(bytes32 => Draw) public draws;                 // key = keccak(cage, drawId)
    mapping(bytes32 => address[]) internal _drawn;
    mapping(bytes32 => mapping(address => bool)) public drawn;
    mapping(uint256 => bytes32) public drawOfRequest;
    uint256 public totalRunnerBonds;
    uint256 public rewardFund;

    event RunnerRegistered(address indexed runner);
    event RunnerBonded(address indexed runner, uint256 amount);
    event DrawRequested(address indexed cage, uint256 indexed drawId, uint256 requestId, uint256 pricePaid);
    /// @dev key = keccak256(abi.encode(cage, drawId)); drawId = taskId << 8 | round
    event DrawFulfilled(address indexed cage, bytes32 indexed key, address[] runners);
    event DrawSettled(address indexed cage, uint256 indexed drawId, uint256 slashed, uint256 paidOut);
    event RunnerSlashed(address indexed runner, uint256 amount);
    event RunnerRewarded(address indexed runner, uint256 amount);

    error NotCage();
    error Runner_();
    error DrawExists();
    error Withdraw_();
    error Length();

    constructor(
        address config_,
        address bondToken_,
        address vrfWrapper_,
        uint256 runnerReserve_,
        uint64 exitCooldown_,
        uint32 callbackGasBase_,
        uint32 callbackGasPerJuror_,
        uint16 requestConfirmations_
    ) NativeVrfConsumer(vrfWrapper_) {
        if (bondToken_ == address(0) || runnerReserve_ == 0 || uint256(callbackGasBase_) + 15 * uint256(callbackGasPerJuror_) > MAX_CALLBACK_GAS) {
            revert Runner_();
        }
        config = config_;
        bondToken = IERC20(bondToken_);
        runnerReserve = runnerReserve_;
        exitCooldown = exitCooldown_;
        callbackGasBase = callbackGasBase_;
        callbackGasPerJuror = callbackGasPerJuror_;
        requestConfirmations = requestConfirmations_;
    }

    modifier onlyCage() {
        if (!IBotledFactoryView(IBotledConfigView(config).factory()).isCage(msg.sender)) revert NotCage();
        _;
    }

    /// @notice ETH that pays VRF draws (anyone: cage callers, forfeited pfands, donations).
    receive() external payable {}

    function fundRewards(uint256 amount) external nonReentrant {
        _pullExact(msg.sender, amount);
        rewardFund += amount;
    }

    // ---------------------------------------------------------------- runners

    /// @notice Registration requires an initial bond >= runnerReserve so the bounded list cannot be
    ///         filled with empty addresses; under-bonded idle runners can be evicted by anyone.
    function registerRunner(uint256 amount) external nonReentrant {
        Runner storage r = runners[msg.sender];
        if (r.listed || runnerList.length >= MAX_RUNNERS || amount < runnerReserve) revert Runner_();
        _pullExact(msg.sender, amount);
        r.listed = true;
        r.bond += amount;
        r.exitReadyAt = 0;
        totalRunnerBonds += amount;
        runnerList.push(msg.sender);
        emit RunnerRegistered(msg.sender);
        emit RunnerBonded(msg.sender, amount);
    }

    /// @notice Permissionless: frees a list slot held by an idle runner whose bond fell below one reserve.
    function evict(address a) external {
        Runner storage r = runners[a];
        if (!r.listed || r.activeCases != 0 || r.bond >= runnerReserve) revert Runner_();
        r.listed = false;
        uint256 len = runnerList.length;
        for (uint256 i; i < len; ++i) {
            if (runnerList[i] == a) {
                runnerList[i] = runnerList[len - 1];
                runnerList.pop();
                return;
            }
        }
    }

    function bondRunner(uint256 amount) external nonReentrant {
        Runner storage r = runners[msg.sender];
        if (!r.listed) revert Runner_();
        _pullExact(msg.sender, amount);
        r.bond += amount;
        r.exitReadyAt = 0;
        totalRunnerBonds += amount;
        emit RunnerBonded(msg.sender, amount);
    }

    function scheduleRunnerExit() external {
        Runner storage r = runners[msg.sender];
        if (!r.listed || r.activeCases != 0) revert Runner_();
        r.exitReadyAt = uint64(block.timestamp) + exitCooldown;
    }

    function withdrawRunner(uint256 amount) external nonReentrant {
        Runner storage r = runners[msg.sender];
        if (r.activeCases != 0 || r.exitReadyAt == 0 || block.timestamp < r.exitReadyAt || amount > r.bond) {
            revert Withdraw_();
        }
        r.bond -= amount;
        totalRunnerBonds -= amount;
        bondToken.safeTransfer(msg.sender, amount);
    }

    function runnerEligible(address a) public view returns (bool) {
        Runner storage r = runners[a];
        return r.listed && r.exitReadyAt == 0 && r.bond >= uint256(r.activeCases + 1) * runnerReserve;
    }

    function runnerCount() external view returns (uint256) { return runnerList.length; }

    // ---------------------------------------------------------------- draws

    function callbackGas(uint8 n) public view returns (uint32) { return callbackGasBase + callbackGasPerJuror * n; }

    function vrfPrice(uint8 n) external view returns (uint256) { return _vrfPrice(callbackGas(n)); }

    /// @return ok false if the pool cannot pay VRF right now (the cage may retry after a top-up).
    function requestDraw(uint256 drawId, address poster, address worker, uint8 n, uint64 fulfillBy)
        external
        onlyCage
        returns (bool ok)
    {
        bytes32 key = keccak256(abi.encode(msg.sender, drawId));
        if (draws[key].cage != address(0)) revert DrawExists();
        uint32 gasLimit = callbackGas(n);
        if (_vrfPrice(gasLimit) > address(this).balance) return false;
        (uint256 id, uint256 paid) = _requestRandom(gasLimit, requestConfirmations);
        draws[key] = Draw(msg.sender, n, false, uint64(block.timestamp), fulfillBy, 0, poster, worker);
        drawOfRequest[id] = key;
        emit DrawRequested(msg.sender, drawId, id, paid);
        return true;
    }

    function _fulfillRandom(uint256 requestId, uint256 word) internal override {
        bytes32 key = drawOfRequest[requestId];
        Draw storage d = draws[key];
        if (d.cage == address(0) || d.fulfilledAt != 0 || d.settled || block.timestamp > d.fulfillBy) return;
        d.fulfilledAt = uint64(block.timestamp);
        uint256 len = runnerList.length;
        address[] storage list = _drawn[key];
        // Independent pick per attempt (no contiguous window => registering adjacent sybils does not cluster).
        for (uint256 attempt; attempt < uint256(d.n) * 4 && list.length < d.n && len > 0; ++attempt) {
            _tryPick(key, d, runnerList[uint256(keccak256(abi.encode(word, attempt))) % len]);
        }
        // Deterministic completion scan from a random offset if random attempts were unlucky.
        uint256 start = len == 0 ? 0 : word % len;
        for (uint256 i; i < len && list.length < d.n; ++i) _tryPick(key, d, runnerList[(start + i) % len]);
        emit DrawFulfilled(d.cage, key, list);
    }

    function _tryPick(bytes32 key, Draw storage d, address a) internal {
        if (drawn[key][a] || a == d.poster || a == d.worker || a == d.cage || !runnerEligible(a)) return;
        drawn[key][a] = true;
        runners[a].activeCases++;
        _drawn[key].push(a);
    }

    function drawInfo(address cage, uint256 drawId)
        external
        view
        returns (uint64 requestedAt, uint64 fulfilledAt, uint256 count, bool settled)
    {
        bytes32 key = keccak256(abi.encode(cage, drawId));
        Draw storage d = draws[key];
        return (d.requestedAt, d.fulfilledAt, _drawn[key].length, d.settled);
    }

    function isDrawn(address cage, uint256 drawId, address runner) external view returns (bool) {
        return drawn[keccak256(abi.encode(cage, drawId))][runner];
    }

    function drawnRunners(address cage, uint256 drawId) external view returns (address[] memory) {
        return _drawn[keccak256(abi.encode(cage, drawId))];
    }

    /// @notice Called once per draw by the owning cage at the end of a case.
    /// @param slashes per drawn runner (same order as drawnRunners), each capped at runnerReserve.
    /// @param rewarded per drawn runner; they share this draw's slashes + `extraReward` from the fund.
    function settleDraw(uint256 drawId, uint256[] calldata slashes, bool[] calldata rewarded, uint256 extraReward)
        external
        nonReentrant
        onlyCage
    {
        bytes32 key = keccak256(abi.encode(msg.sender, drawId));
        Draw storage d = draws[key];
        if (d.cage != msg.sender || d.settled) revert DrawExists();
        d.settled = true;
        address[] storage list = _drawn[key];
        if (slashes.length != list.length || rewarded.length != list.length) revert Length();

        uint256 winners;
        uint256 slashed;
        for (uint256 i; i < list.length; ++i) {
            Runner storage r = runners[list[i]];
            r.activeCases--;
            if (rewarded[i]) winners++;
            uint256 cut = slashes[i] > runnerReserve ? runnerReserve : slashes[i];
            if (cut > r.bond) cut = r.bond;
            if (cut > 0) {
                r.bond -= cut;
                slashed += cut;
                emit RunnerSlashed(list[i], cut);
            }
        }
        uint256 extra = extraReward <= rewardFund ? extraReward : rewardFund;
        uint256 paid;
        if (winners == 0) {
            rewardFund += slashed; // nobody coherent: slashes fund future rounds
        } else {
            rewardFund -= extra;
            uint256 share = (slashed + extra) / winners;
            for (uint256 i; i < list.length; ++i) {
                if (!rewarded[i]) continue;
                runners[list[i]].bond += share; // auto-compound
                emit RunnerRewarded(list[i], share);
            }
            paid = share * winners;
            rewardFund += slashed + extra - paid; // rounding dust
        }
        totalRunnerBonds = totalRunnerBonds - slashed + paid;
        emit DrawSettled(msg.sender, drawId, slashed, paid);
    }

    function _pullExact(address from, uint256 amount) internal {
        if (amount == 0) revert Runner_();
        uint256 beforeBal = bondToken.balanceOf(address(this));
        bondToken.safeTransferFrom(from, address(this), amount);
        if (bondToken.balanceOf(address(this)) - beforeBal != amount) revert Runner_();
    }
}
