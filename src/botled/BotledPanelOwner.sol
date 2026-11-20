// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @dev Owner surface of Azzle `ArbitrationModuleV2` (V2Ownable2Step) that this contract drives.
interface IPanelModule {
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function acceptOwnership() external;
    function addPanelMember(address member) external;
    function removePanelMember(address member) external;
    function authorized(address member) external view returns (bool);
    function panelLength() external view returns (uint256);
    function bonds() external view returns (address);
}

/// @dev Public views of Azzle `VerifierBondVaultV2`.
interface IPanelVault {
    function isEligible(address verifier) external view returns (bool);
    function canRelease(address verifier) external view returns (bool); // == activeAssignments > 0
}

/// @title BotledPanelOwner
/// @notice Becomes the owner of BOTH Azzle ArbitrationModuleV2 instances (micro + standard) and turns
///         panel membership into a permissionless, bonded seat:
///           join()  – caller already bonded >= minimumBond in BOTH vaults (10k std + 1k micro = 11k AZL)
///                     and pays the ETH pfand -> added to both panels.
///           leave() – removes the caller from both panels and refunds the pfand (only with no open dispute).
///           kick(m) – anyone removes a seat that is no longer eligible in a vault; pfand is forfeited.
///         Every other owner power over the modules is reachable ONLY by the Azzle Safe through a
///         7-day timelock (generic, value-less call forwarding), including handing ownership back.
/// @dev All checks are O(1) view calls on the vaults (no loops over tasks or panels in this contract).
///      The module's own `removePanelMember` still scans `panel` linearly; `maxPanelLength` bounds that.
///      Sybil: one operator may hold many seats with many addresses. Accepted by design: each seat costs
///      11k AZL bonded + the pfand and assignment is round-robin, so N seats give N/len of the cases and
///      N times the slashable stake.
contract BotledPanelOwner is ReentrancyGuard {
    uint256 public constant TIMELOCK_DELAY = 7 days;

    address public immutable safe;
    IPanelModule public immutable micro;
    IPanelModule public immutable standard;
    IPanelVault public immutable microVault;
    IPanelVault public immutable standardVault;

    /// @notice ETH pfand required per seat (changeable only via Safe + timelock; existing seats keep theirs).
    uint256 public pfand;
    /// @notice join() refuses once either module's `panel` array reaches this length (array never shrinks).
    uint256 public maxPanelLength;
    /// @notice Recipient of forfeited pfands on kick(); address(0) = the kicker (keeper bounty).
    address public forfeitRecipient;

    struct Seat {
        bool seated;
        uint128 pfand;
    }

    mapping(address => Seat) public seats;
    uint256 public seatCount;
    /// @notice ETH owed to accounts whose push transfer failed (pull via claim()).
    mapping(address => uint256) public claimable;
    /// @notice Timelocked operation id => earliest execution time (0 = not scheduled).
    mapping(bytes32 => uint256) public readyAt;

    event Joined(address indexed member, uint256 pfand);
    event Left(address indexed member, uint256 refund);
    event Kicked(address indexed member, address indexed kicker, address indexed recipient, uint256 pfand);
    event CallScheduled(bytes32 indexed id, address indexed target, bytes data, bytes32 salt, uint256 readyAt);
    event CallExecuted(bytes32 indexed id, address indexed target, bytes data);
    event CallCancelled(bytes32 indexed id);
    event ConfigChanged(uint256 pfand, uint256 maxPanelLength, address forfeitRecipient);
    event Credited(address indexed account, uint256 amount);

    error OnlySafe();
    error OnlySelf();
    error BadPfand();
    error AlreadySeated();
    error NotSeated();
    error AlreadyOnPanel();
    error NotEligible();
    error StillEligible();
    error MemberBusy();
    error PanelFull();
    error NotModuleOwner();
    error BadTarget();
    error NotReady();
    error UnknownCall();
    error AlreadyScheduled();
    error CallFailed(bytes reason);
    error Config();
    error NothingToClaim();

    modifier onlySafe() {
        if (msg.sender != safe) revert OnlySafe();
        _;
    }

    modifier onlySelf() {
        if (msg.sender != address(this)) revert OnlySelf();
        _;
    }

    constructor(
        address safe_,
        IPanelModule micro_,
        IPanelModule standard_,
        uint256 pfand_,
        uint256 maxPanelLength_,
        address forfeitRecipient_
    ) {
        if (safe_ == address(0) || address(micro_) == address(standard_) || pfand_ == 0) revert Config();
        safe = safe_;
        micro = micro_;
        standard = standard_;
        microVault = IPanelVault(micro_.bonds());
        standardVault = IPanelVault(standard_.bonds());
        if (address(microVault) == address(standardVault)) revert Config();
        _setConfig(pfand_, maxPanelLength_, forfeitRecipient_);
    }

    // ------------------------------------------------------------------ ownership intake

    /// @notice Completes the Safe's `transferOwnership(this)` on both modules (Ownable2Step).
    /// @dev Permissionless and harmless: only succeeds where this contract is the pending owner.
    function acceptModuleOwnership() external {
        if (micro.pendingOwner() == address(this)) micro.acceptOwnership();
        if (standard.pendingOwner() == address(this)) standard.acceptOwnership();
    }

    function ownsModules() public view returns (bool) {
        return micro.owner() == address(this) && standard.owner() == address(this);
    }

    // ------------------------------------------------------------------ permissionless seats

    /// @notice Join both panels. Bond first, from THIS address, directly in each vault:
    ///         standardVault.bond(10_000e18) and microVault.bond(1_000e18) (vaults credit msg.sender only).
    function join() external payable nonReentrant {
        address m = msg.sender;
        if (seats[m].seated) revert AlreadySeated();
        if (msg.value != pfand) revert BadPfand();
        if (!ownsModules()) revert NotModuleOwner();
        if (micro.authorized(m) || standard.authorized(m)) revert AlreadyOnPanel();
        if (!microVault.isEligible(m) || !standardVault.isEligible(m)) revert NotEligible();
        if (micro.panelLength() >= maxPanelLength || standard.panelLength() >= maxPanelLength) revert PanelFull();

        seats[m] = Seat({seated: true, pfand: uint128(msg.value)});
        ++seatCount;
        micro.addPanelMember(m);
        standard.addPanelMember(m);
        emit Joined(m, msg.value);
    }

    /// @notice Leave both panels and get the pfand back. Reverts while the member holds an open
    ///         dispute assignment in either module (the module itself also forbids removing it then).
    /// @dev If governance has taken a module back (ownership handed back), removal there is skipped
    ///      so a pfand can never be stuck in this contract.
    function leave() external nonReentrant {
        address m = msg.sender;
        Seat memory s = seats[m];
        if (!s.seated) revert NotSeated();
        if (microVault.canRelease(m) || standardVault.canRelease(m)) revert MemberBusy();
        _close(m);
        _removeIfOwnedAndListed(micro, m);
        _removeIfOwnedAndListed(standard, m);
        _pay(m, s.pfand);
        emit Left(m, s.pfand);
    }

    /// @notice Remove a seat that is no longer eligible in at least one vault (bond below minimum,
    ///         slashed, or withdrawal scheduled). The pfand goes to `forfeitRecipient` or the kicker.
    /// @dev A member busy with an open dispute cannot be kicked (module: "active assignment").
    function kick(address m) external nonReentrant {
        Seat memory s = seats[m];
        if (!s.seated) revert NotSeated();
        if (!ownsModules()) revert NotModuleOwner();
        if (microVault.isEligible(m) && standardVault.isEligible(m)) revert StillEligible();
        if (microVault.canRelease(m) || standardVault.canRelease(m)) revert MemberBusy();
        _close(m);
        _removeIfOwnedAndListed(micro, m);
        _removeIfOwnedAndListed(standard, m);
        address to = forfeitRecipient == address(0) ? msg.sender : forfeitRecipient;
        _pay(to, s.pfand);
        emit Kicked(m, msg.sender, to, s.pfand);
    }

    /// @notice Pull ETH whose push transfer failed (e.g. a contract member without receive()).
    function claim() external nonReentrant {
        uint256 amount = claimable[msg.sender];
        if (amount == 0) revert NothingToClaim();
        claimable[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert CallFailed("");
    }

    function isSeated(address m) external view returns (bool) {
        return seats[m].seated;
    }

    /// @notice O(1) view a keeper can poll before calling kick().
    function kickable(address m) external view returns (bool) {
        return seats[m].seated && ownsModules() && !(microVault.isEligible(m) && standardVault.isEligible(m))
            && !microVault.canRelease(m) && !standardVault.canRelease(m);
    }

    // ------------------------------------------------------------------ Safe + 7-day timelock

    /// @notice Operation id for a timelocked call. Targets: micro, standard, or this contract (config).
    function hashCall(address target, bytes calldata data, bytes32 salt) public pure returns (bytes32) {
        return keccak256(abi.encode(target, data, salt));
    }

    function schedule(address target, bytes calldata data, bytes32 salt) external onlySafe returns (bytes32 id) {
        if (target != address(micro) && target != address(standard) && target != address(this)) revert BadTarget();
        id = hashCall(target, data, salt);
        if (readyAt[id] != 0) revert AlreadyScheduled();
        uint256 eta = block.timestamp + TIMELOCK_DELAY;
        readyAt[id] = eta;
        emit CallScheduled(id, target, data, salt, eta);
    }

    function cancel(bytes32 id) external onlySafe {
        if (readyAt[id] == 0) revert UnknownCall();
        delete readyAt[id];
        emit CallCancelled(id);
    }

    /// @notice Executes a scheduled call. Never forwards ETH, so seat pfands are out of governance's reach.
    function execute(address target, bytes calldata data, bytes32 salt) external onlySafe nonReentrant returns (bytes memory ret) {
        bytes32 id = hashCall(target, data, salt);
        uint256 eta = readyAt[id];
        if (eta == 0) revert UnknownCall();
        if (block.timestamp < eta) revert NotReady();
        delete readyAt[id];
        bool ok;
        (ok, ret) = target.call(data);
        if (!ok) revert CallFailed(ret);
        emit CallExecuted(id, target, data);
    }

    /// @notice Only reachable as a timelocked self-call. New pfand applies to future seats only.
    function setConfig(uint256 pfand_, uint256 maxPanelLength_, address forfeitRecipient_) external onlySelf {
        _setConfig(pfand_, maxPanelLength_, forfeitRecipient_);
    }

    // ------------------------------------------------------------------ internals

    function _setConfig(uint256 pfand_, uint256 maxPanelLength_, address forfeitRecipient_) internal {
        if (pfand_ == 0 || pfand_ > type(uint128).max || maxPanelLength_ == 0) revert Config();
        pfand = pfand_;
        maxPanelLength = maxPanelLength_;
        forfeitRecipient = forfeitRecipient_;
        emit ConfigChanged(pfand_, maxPanelLength_, forfeitRecipient_);
    }

    function _close(address m) internal {
        delete seats[m];
        --seatCount;
    }

    function _removeIfOwnedAndListed(IPanelModule module, address m) internal {
        if (module.owner() == address(this) && module.authorized(m)) module.removePanelMember(m);
    }

    function _pay(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount, gas: 50_000}("");
        if (!ok) {
            claimable[to] += amount;
            emit Credited(to, amount);
        }
    }
}
