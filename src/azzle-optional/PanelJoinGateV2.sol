// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {NativeVrfConsumer} from "../shared/NativeVrfConsumer.sol";

interface IGovSafe {
    enum Operation { Call, DelegateCall }
    function execTransactionFromModule(address to, uint256 value, bytes calldata data, Operation operation)
        external
        returns (bool success);
}

interface IPanelArbitrationV2 {
    function bonds() external view returns (address);
    function authorized(address member) external view returns (bool);
    function panelLength() external view returns (uint256);
    function addPanelMember(address member) external;
    function removePanelMember(address member) external;
}

interface IPanelBondV2 {
    function minimumBond() external view returns (uint256);
    function bonds(address verifier) external view returns (uint256);
    function isEligible(address verifier) external view returns (bool);
    function canRelease(address verifier) external view returns (bool);
}

/// @notice Optional admission policy (e.g. BotledFactory.admits). address(0) = open admission.
interface IAdmissionPolicy {
    function admits(address member, address arbitration) external view returns (bool);
}

/// @title PanelJoinGateV2 — OPTIONAL Azzle-side replacement for the deployed PanelJoinGate
/// @notice Safe module on the Azzle governance Safe (owner of both ArbitrationModuleV2 instances).
///         Same entry point as the deployed gate (`joinPanel(arbitration)` payable, `ethOf`, `ethPfand`,
///         `bondTarget`, `withdrawEth`), but:
///         - two-phase join: request -> fixed minDelay + VRF-random extra delay -> permissionless `activate`
///         - at most one join request per epoch per panel, hard cap on `panelLength()`
///         - eligibility via `vault.isEligible` at request AND activation
///         - permissionless `prune` of ineligible, unassigned members (Safe-module path; no module change)
///         - pfand forfeiture if a member leaves (is pruned) before `minService`
///         - optional admission policy (e.g. only factory-born LLM cages)
/// @dev Works on Safe 1.4.1 without a module guard: the gate itself can only produce
///      `addPanelMember`/`removePanelMember` calls on the two configured modules.
///      ArbitrationModuleV2 never shrinks `panel` (removal zeroes the slot), so `panelCap` is a
///      LIFETIME cap on slots — size it accordingly.
contract PanelJoinGateV2 is NativeVrfConsumer, ReentrancyGuard {
    struct Join {
        uint64 requestedAt;
        uint64 readyAt; // 0 until VRF fulfilled
        uint256 requestId;
    }

    struct Request {
        address member;
        address arbitration;
    }

    address public immutable safe;
    address public immutable standardArbitration;
    address public immutable microArbitration;
    IAdmissionPolicy public immutable policy;
    address public immutable forfeitSink;
    uint256 public immutable ethPfand;
    uint256 public immutable bondFloor;      // deployed gate: AZL_PFAND = 10_000 ether
    uint64 public immutable minDelay;
    uint64 public immutable maxExtraDelay;
    uint64 public immutable epochLength;
    uint64 public immutable minService;
    uint256 public immutable panelCap;
    uint32 public immutable vrfCallbackGas;

    mapping(address => uint256) public ethOf;
    mapping(address => mapping(address => Join)) public joins;
    mapping(address => mapping(address => uint64)) public joinedAt;
    mapping(address => bool) public forfeited;
    mapping(address => uint64) public lastRequestEpochPlusOne;
    mapping(uint256 => Request) public requests;

    event JoinRequested(address indexed member, address indexed arbitration, uint256 requestId, uint256 vrfPaid);
    event JoinScheduled(address indexed member, address indexed arbitration, uint64 readyAt);
    event PanelJoined(address indexed member, address indexed arbitration);
    event Pruned(address indexed member, address indexed arbitration, bool forfeited);
    event EthWithdrawn(address indexed member, address indexed to, uint256 amount);

    error BadConfig();
    error UnknownPanel();
    error NotAdmitted();
    error AlreadyPanel();
    error Pending();
    error EpochUsed();
    error PanelFull();
    error Unbonded();
    error EthPfand();
    error NotReady();
    error NotPrunable();
    error StillPanel();
    error JoinFailed();

    constructor(
        address safe_,
        address standard_,
        address micro_,
        address policy_,
        address forfeitSink_,
        address vrfWrapper_,
        uint256 ethPfand_,
        uint256 bondFloor_,
        uint64[4] memory delays, // minDelay, maxExtraDelay, epochLength, minService
        uint256 panelCap_,
        uint32 vrfCallbackGas_
    ) NativeVrfConsumer(vrfWrapper_) {
        if (safe_.code.length == 0 || standard_.code.length == 0 || micro_.code.length == 0 || standard_ == micro_) {
            revert BadConfig();
        }
        if (forfeitSink_ == address(0) || ethPfand_ == 0 || delays[2] == 0) revert BadConfig();
        safe = safe_;
        standardArbitration = standard_;
        microArbitration = micro_;
        policy = IAdmissionPolicy(policy_);
        forfeitSink = forfeitSink_;
        ethPfand = ethPfand_;
        bondFloor = bondFloor_;
        minDelay = delays[0];
        maxExtraDelay = delays[1];
        epochLength = delays[2];
        minService = delays[3];
        panelCap = panelCap_;
        vrfCallbackGas = vrfCallbackGas_;
    }

    function known(address a) public view returns (bool) { return a == standardArbitration || a == microArbitration; }

    function bondTarget(address arbitration) public view returns (uint256) {
        if (!known(arbitration)) revert UnknownPanel();
        uint256 minimum = IPanelBondV2(IPanelArbitrationV2(arbitration).bonds()).minimumBond();
        return minimum > bondFloor ? minimum : bondFloor;
    }

    /// @notice Quote for `msg.value`: pfand (first join only) + VRF fee.
    function joinCost(address member) external view returns (uint256) {
        return (ethOf[member] == 0 ? ethPfand : 0) + _vrfPrice(vrfCallbackGas);
    }

    /// @notice Phase 1. `msg.sender` is the member (a cage calls this directly and pays itself).
    function joinPanel(address arbitration) external payable nonReentrant {
        address m = msg.sender;
        _checkAdmissible(m, arbitration);
        Join storage j = joins[m][arbitration];
        if (j.requestedAt != 0) revert Pending();
        uint64 epochPlusOne = uint64(block.timestamp / epochLength) + 1;
        if (lastRequestEpochPlusOne[arbitration] == epochPlusOne) revert EpochUsed();
        lastRequestEpochPlusOne[arbitration] = epochPlusOne;

        uint256 price = _vrfPrice(vrfCallbackGas);
        uint256 due = (ethOf[m] == 0 ? ethPfand : 0) + price;
        if (msg.value < due) revert EthPfand();
        ethOf[m] += msg.value - price; // VRF fee is the only non-refundable part
        (uint256 id, uint256 paid) = _requestRandom(vrfCallbackGas, 3);
        j.requestedAt = uint64(block.timestamp);
        j.requestId = id;
        requests[id] = Request(m, arbitration);
        emit JoinRequested(m, arbitration, id, paid);
    }

    function _fulfillRandom(uint256 requestId, uint256 word) internal override {
        Request memory r = requests[requestId];
        Join storage j = joins[r.member][r.arbitration];
        if (r.member == address(0) || j.requestId != requestId || j.readyAt != 0) return;
        j.readyAt = j.requestedAt + minDelay + uint64(word % (uint256(maxExtraDelay) + 1));
        emit JoinScheduled(r.member, r.arbitration, j.readyAt);
    }

    /// @notice Phase 2, permissionless after the random delay. Re-checks everything.
    function activate(address member, address arbitration) external nonReentrant {
        Join storage j = joins[member][arbitration];
        if (j.readyAt == 0 || block.timestamp < j.readyAt) revert NotReady();
        _checkAdmissible(member, arbitration);
        delete joins[member][arbitration];
        joinedAt[member][arbitration] = uint64(block.timestamp);
        _exec(arbitration, abi.encodeCall(IPanelArbitrationV2.addPanelMember, (member)));
        emit PanelJoined(member, arbitration);
    }

    /// @notice Member abandons a pending request (VRF fee is lost, pfand stays withdrawable).
    function cancelJoin(address arbitration) external {
        if (joins[msg.sender][arbitration].requestedAt == 0) revert NotReady();
        delete joins[msg.sender][arbitration];
    }

    /// @notice Permissionless removal of members the module would never assign anyway.
    /// @dev ArbitrationModuleV2.removePanelMember is onlyOwner; this works because the gate is a module
    ///      of the owner Safe. Conditions mirror the module: no active assignment (`canRelease` false);
    ///      we only prune when `isEligible` is false, so the "final eligible member" rule never trips.
    function prune(address arbitration, address member) external nonReentrant {
        if (!known(arbitration)) revert UnknownPanel();
        IPanelBondV2 vault = IPanelBondV2(IPanelArbitrationV2(arbitration).bonds());
        if (!IPanelArbitrationV2(arbitration).authorized(member) || vault.isEligible(member) || vault.canRelease(member)) {
            revert NotPrunable();
        }
        uint64 since = joinedAt[member][arbitration];
        bool early = since != 0 && block.timestamp < uint256(since) + minService;
        if (early) forfeited[member] = true;
        delete joinedAt[member][arbitration];
        _exec(arbitration, abi.encodeCall(IPanelArbitrationV2.removePanelMember, (member)));
        emit Pruned(member, arbitration, early);
    }

    /// @notice Refund (or forfeit) the pfand once off both panels with no pending join / assignment.
    function withdrawEth() external nonReentrant {
        address m = msg.sender;
        uint256 amount = ethOf[m];
        if (amount == 0) revert EthPfand();
        if (_onPanel(m) || _assigned(m)) revert StillPanel();
        if (joins[m][standardArbitration].requestedAt != 0 || joins[m][microArbitration].requestedAt != 0) revert Pending();
        ethOf[m] = 0;
        address to = forfeited[m] ? forfeitSink : m;
        forfeited[m] = false;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthPfand();
        emit EthWithdrawn(m, to, amount);
    }

    function _checkAdmissible(address m, address arbitration) internal view {
        if (!known(arbitration)) revert UnknownPanel();
        if (address(policy) != address(0) && !policy.admits(m, arbitration)) revert NotAdmitted();
        if (IPanelArbitrationV2(arbitration).authorized(m)) revert AlreadyPanel();
        if (IPanelArbitrationV2(arbitration).panelLength() >= panelCap) revert PanelFull();
        IPanelBondV2 vault = IPanelBondV2(IPanelArbitrationV2(arbitration).bonds());
        if (vault.bonds(m) < bondTarget(arbitration) || !vault.isEligible(m)) revert Unbonded();
    }

    function _exec(address to, bytes memory data) internal {
        if (!IGovSafe(safe).execTransactionFromModule(to, 0, data, IGovSafe.Operation.Call)) revert JoinFailed();
    }

    function _onPanel(address a) internal view returns (bool) {
        return IPanelArbitrationV2(standardArbitration).authorized(a) || IPanelArbitrationV2(microArbitration).authorized(a);
    }

    function _assigned(address a) internal view returns (bool) {
        return IPanelBondV2(IPanelArbitrationV2(standardArbitration).bonds()).canRelease(a)
            || IPanelBondV2(IPanelArbitrationV2(microArbitration).bonds()).canRelease(a);
    }
}
