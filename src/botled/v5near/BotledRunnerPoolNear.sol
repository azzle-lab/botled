// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {NativeVrfConsumer} from "../../shared/NativeVrfConsumer.sol";

interface IFactoryCages {
    function isCage(address cage) external view returns (bool);
}

interface IEnrollSignerSource {
    function enrollSigner() external view returns (address);
}

/// @title Botled v5/NEAR — runner pool without bonds
/// @notice A runner is a Base address controlled by a NEAR account through NEAR Chain Signatures. It is listed by an
///         ENROLLMENT TICKET: an EIP-712 message signed by the NEAR MPC network for the Botled NEAR registry
///         contract (BotledNearConfig.enrollSigner = MPC key derived for (registry account, path)). The registry only
///         asks the MPC network to sign after the runner paid its $20 signup and has budget left, and it states how
///         many no-shows the runner has already paid for.
///
///         No AZL bond and no minority slash: every vote carries a NEAR AI receipt, so a runner cannot vote anything
///         but the pinned model's answer. The only fault left is liveness. A drawn runner without a valid reveal gets
///         `noShows += 1` and is not drawn again until a fresh ticket covers that count (the NEAR registry charges the
///         no-show penalty from the runner's budget before it signs that ticket). Tickets expire (`validUntil`), so a
///         runner whose budget ran dry on NEAR drops out of the draw automatically.
///
///         Rewards are optional, paid from `rewardFund` (any ERC-20, e.g. USDC or AZL) equally to every drawn runner
///         who revealed a valid receipt — not to the majority: with proven model outputs there is nothing to herd to.
/// @dev No owner. Only cages of the anchored factory may request draws or settle.
contract BotledRunnerPoolNear is NativeVrfConsumer, ReentrancyGuard, EIP712 {
    using SafeERC20 for IERC20;

    struct Runner {
        bool listed;
        uint32 activeCases;
        uint32 noShows;          // lifetime no-shows recorded by cages
        uint32 noShowsCovered;   // from the latest ticket
        uint32 epoch;            // latest ticket epoch (strictly increasing)
        uint64 validUntil;
        bytes32 nearAccount;     // keccak256(NEAR account id), fixed at first enrollment
        address sessionKey;      // from the latest ticket: may sign relayed commits for `runner` (no MPC call per commit)
    }

    struct Draw {
        address cage;
        uint8 n;
        bool settled;
        uint64 requestedAt;
        uint64 fulfillBy;
        uint64 fulfilledAt;
        address poster;
        address worker;
    }

    bytes32 public constant ENROLL_TYPEHASH =
        keccak256(
            "Enroll(address runner,bytes32 nearAccount,uint32 epoch,uint32 noShowsCovered,uint64 validUntil,address sessionKey)"
        );
    uint256 public constant MAX_RUNNERS = 128;
    uint32 public constant MAX_CALLBACK_GAS = 2_400_000;

    address public immutable factory;          // trust anchor (isCage)
    address public immutable nearConfig;       // enrollSigner source (timelocked)
    IERC20 public immutable rewardToken;
    uint32 public immutable maxConcurrent;     // parallel draws per runner
    uint32 public immutable callbackGasBase;
    uint32 public immutable callbackGasPerJuror;
    uint16 public immutable requestConfirmations;

    address[] public runnerList;
    mapping(address => Runner) public runners;
    mapping(bytes32 => address) public runnerOfNear; // one Base runner per NEAR account
    mapping(bytes32 => Draw) public draws;
    mapping(bytes32 => address[]) internal _drawn;
    /// @notice 1-based seat in the VRF-ordered draw (0 = not drawn). The cage derives the seat's model lane from it.
    mapping(bytes32 => mapping(address => uint8)) public seatOf;
    mapping(uint256 => bytes32) public drawOfRequest;
    mapping(address => uint256) public rewards;
    uint256 public rewardFund;

    event RunnerEnrolled(
        address indexed runner, bytes32 indexed nearAccount, uint32 epoch, uint32 noShowsCovered, uint64 validUntil, address sessionKey
    );
    event RunnerDelisted(address indexed runner);
    event DrawRequested(address indexed cage, uint256 indexed drawId, uint256 requestId, uint256 pricePaid);
    event DrawFulfilled(address indexed cage, bytes32 indexed key, address[] runners);
    event DrawSettled(address indexed cage, uint256 indexed drawId, uint256 noShows, uint256 paidOut);
    event NoShow(address indexed runner, uint32 total);
    event RunnerRewarded(address indexed runner, uint256 amount);

    error NotCage();
    error Runner_();
    error Ticket();
    error DrawExists();
    error Length();

    constructor(
        address factory_,
        address nearConfig_,
        address rewardToken_,
        address vrfWrapper_,
        uint32 maxConcurrent_,
        uint32 callbackGasBase_,
        uint32 callbackGasPerJuror_,
        uint16 requestConfirmations_
    ) NativeVrfConsumer(vrfWrapper_) EIP712("BotledRunnerPoolNear", "1") {
        if (
            rewardToken_ == address(0) || maxConcurrent_ == 0
                || uint256(callbackGasBase_) + 15 * uint256(callbackGasPerJuror_) > MAX_CALLBACK_GAS
        ) revert Runner_();
        factory = factory_;
        nearConfig = nearConfig_;
        rewardToken = IERC20(rewardToken_);
        maxConcurrent = maxConcurrent_;
        callbackGasBase = callbackGasBase_;
        callbackGasPerJuror = callbackGasPerJuror_;
        requestConfirmations = requestConfirmations_;
    }

    /// @notice Pool trust anchor surface (same shape as BotledRunnerPool.config()).
    function config() external view returns (address) { return factory; }

    modifier onlyCage() {
        if (!IFactoryCages(factory).isCage(msg.sender)) revert NotCage();
        _;
    }

    receive() external payable {}

    function fundRewards(uint256 amount) external nonReentrant {
        if (amount == 0) revert Runner_();
        uint256 before = rewardToken.balanceOf(address(this));
        rewardToken.safeTransferFrom(msg.sender, address(this), amount);
        rewardFund += rewardToken.balanceOf(address(this)) - before;
    }

    // ---------------------------------------------------------------- enrollment (NEAR -> Base)

    function enrollDigest(
        address runner,
        bytes32 nearAccount,
        uint32 epoch,
        uint32 noShowsCovered,
        uint64 validUntil,
        address sessionKey
    ) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(abi.encode(ENROLL_TYPEHASH, runner, nearAccount, epoch, noShowsCovered, validUntil, sessionKey))
        );
    }

    /// @notice Permissionless relay of a ticket signed by the NEAR MPC network for the Botled registry.
    ///         `sessionKey` is a fresh key the runner generated for this ticket (0 = commits only via Chain Signatures).
    function enroll(
        address runner,
        bytes32 nearAccount,
        uint32 epoch,
        uint32 noShowsCovered,
        uint64 validUntil,
        address sessionKey,
        bytes calldata sig
    ) external {
        address signer = ECDSA.recover(enrollDigest(runner, nearAccount, epoch, noShowsCovered, validUntil, sessionKey), sig);
        if (signer != IEnrollSignerSource(nearConfig).enrollSigner() || validUntil <= block.timestamp || runner == address(0)) {
            revert Ticket();
        }
        Runner storage r = runners[runner];
        if (epoch <= r.epoch) revert Ticket(); // replay / out-of-order
        if (r.nearAccount == 0) {
            if (runnerOfNear[nearAccount] != address(0)) revert Ticket();
            r.nearAccount = nearAccount;
            runnerOfNear[nearAccount] = runner;
        } else if (r.nearAccount != nearAccount) {
            revert Ticket();
        }
        if (!r.listed) {
            if (runnerList.length >= MAX_RUNNERS) revert Runner_();
            r.listed = true;
            runnerList.push(runner);
        }
        r.epoch = epoch;
        r.noShowsCovered = noShowsCovered;
        r.validUntil = validUntil;
        r.sessionKey = sessionKey;
        emit RunnerEnrolled(runner, nearAccount, epoch, noShowsCovered, validUntil, sessionKey);
    }

    /// @notice Permissionless: frees the list slot of an idle runner whose ticket expired or who owes no-shows.
    function delist(address a) external {
        Runner storage r = runners[a];
        if (!r.listed || r.activeCases != 0 || (r.validUntil > block.timestamp && r.noShows <= r.noShowsCovered)) revert Runner_();
        r.listed = false;
        uint256 len = runnerList.length;
        for (uint256 i; i < len; ++i) {
            if (runnerList[i] == a) {
                runnerList[i] = runnerList[len - 1];
                runnerList.pop();
                break;
            }
        }
        emit RunnerDelisted(a);
    }

    function runnerEligible(address a) public view returns (bool) {
        Runner storage r = runners[a];
        return r.listed && r.validUntil > block.timestamp && r.noShows <= r.noShowsCovered && r.activeCases < maxConcurrent;
    }

    function runnerCount() external view returns (uint256) { return runnerList.length; }

    /// @notice Rewards are pushed to the runner address only (callable by anyone, e.g. a relayer).
    function claimRewards(address runner) external nonReentrant {
        uint256 amt = rewards[runner];
        if (amt == 0) revert Runner_();
        rewards[runner] = 0;
        rewardToken.safeTransfer(runner, amt);
    }

    // ---------------------------------------------------------------- draws (same VRF mechanics as v4/v5)

    function callbackGas(uint8 n) public view returns (uint32) { return callbackGasBase + callbackGasPerJuror * n; }

    function vrfPrice(uint8 n) external view returns (uint256) { return _vrfPrice(callbackGas(n)); }

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
        for (uint256 attempt; attempt < uint256(d.n) * 4 && list.length < d.n && len > 0; ++attempt) {
            _tryPick(key, d, runnerList[uint256(keccak256(abi.encode(word, attempt))) % len]);
        }
        uint256 start = len == 0 ? 0 : word % len;
        for (uint256 i; i < len && list.length < d.n; ++i) _tryPick(key, d, runnerList[(start + i) % len]);
        emit DrawFulfilled(d.cage, key, list);
    }

    function _tryPick(bytes32 key, Draw storage d, address a) internal {
        if (seatOf[key][a] != 0 || a == d.poster || a == d.worker || a == d.cage || !runnerEligible(a)) return;
        runners[a].activeCases++;
        _drawn[key].push(a);
        seatOf[key][a] = uint8(_drawn[key].length);
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

    /// @notice 1-based seat of `runner` in the draw, 0 if not drawn.
    function seat(address cage, uint256 drawId, address runner) external view returns (uint8) {
        return seatOf[keccak256(abi.encode(cage, drawId))][runner];
    }

    function sessionKeyOf(address runner) external view returns (address) {
        return runners[runner].sessionKey;
    }

    function drawnRunners(address cage, uint256 drawId) external view returns (address[] memory) {
        return _drawn[keccak256(abi.encode(cage, drawId))];
    }

    /// @notice Called once per draw by the owning cage when the case ends.
    /// @param status   per drawn runner (drawnRunners order): 0 = no reveal, 1 = liveness reveal (own NEAR AI key; no
    ///                 no-show, no reward), 2 = counted vote (sponsored receipt; shares the reward)
    /// @param penalize false if the case could not be revealed by anyone (e.g. evidence never bound) -> no no-shows
    /// @param reward   amount from rewardFund split equally among counted voters (capped by the fund)
    function settleDraw(uint256 drawId, uint8[] calldata status, bool penalize, uint256 reward) external nonReentrant onlyCage {
        bytes32 key = keccak256(abi.encode(msg.sender, drawId));
        Draw storage d = draws[key];
        if (d.cage != msg.sender || d.settled) revert DrawExists();
        d.settled = true;
        address[] storage list = _drawn[key];
        if (status.length != list.length) revert Length();
        uint256 winners;
        uint256 misses;
        for (uint256 i; i < list.length; ++i) {
            Runner storage r = runners[list[i]];
            r.activeCases--;
            if (status[i] == 2) {
                winners++;
            } else if (status[i] == 0 && penalize) {
                misses++;
                emit NoShow(list[i], ++r.noShows);
            }
        }
        uint256 paid;
        if (winners > 0 && reward > 0) {
            if (reward > rewardFund) reward = rewardFund;
            uint256 share = reward / winners;
            for (uint256 i; i < list.length; ++i) {
                if (status[i] != 2) continue;
                rewards[list[i]] += share;
                emit RunnerRewarded(list[i], share);
            }
            paid = share * winners;
            rewardFund -= paid;
        }
        emit DrawSettled(msg.sender, drawId, misses, paid);
    }

    /// @notice Appeal-bond forfeits from cages land here.
    function fundRewardsFromCage(uint256 amount) external nonReentrant onlyCage {
        rewardToken.safeTransferFrom(msg.sender, address(this), amount);
        rewardFund += amount;
    }
}
