// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title Botled v4 — central configuration (no TEE, no guardian, no human arbiter)
/// @notice Genesis constitution, params and supported Azzle modules are fixed in the constructor
///         (public at deploy time, active immediately). Every later change is timelocked.
///         The owner can additionally revoke a constitution at once; that only blocks NEW seats,
///         it never touches a running case. Nobody can rule, pick runners or move funds.
contract BotledConfig is Ownable2Step {
    uint256 public constant MAX_LANES = 8;
    uint64 public constant MIN_TIMELOCK = 1 days;

    /// @dev One lane = one pinned (Surplus model id, Surplus provider) pair, e.g. ("claude-opus-5","anthropic").
    ///      Runners reveal the lane index they used; provider diversity counts distinct lanes.
    struct Lane {
        bytes32 model;
        bytes32 provider;
    }

    struct Constitution {
        bytes32 promptTemplateHash; // keccak256 of the prompt template file
        bytes32 rubricHash;         // ruling rubric
        bytes32 schemaHash;         // strict JSON schema of the answer
        bytes32 decodingHash;       // temperature 0, seed, max_tokens
        uint64 activeAt;
        bool revoked;
    }

    struct Params {
        uint8[3] jurySizes;     // odd, non-decreasing, 1..15 (production 3/7/15)
        uint8 minProviders;     // a majority needs reveals from >= this many distinct lanes (1 = off)
        uint32 vrfTimeout;      // max wait for the VRF draw
        uint32 commitWindow;    // after the draw
        uint32 revealWindow;
        uint32 appealWindow;    // after a non-final verdict
        uint32 safetyMargin;    // hard stop before Azzle's rulingDeadline
        uint128[2] appealBonds; // bond token: appeal into round 2 / round 3
        uint128 noShowSlash;    // drawn but no valid reveal
        uint128 minoritySlash;  // revealed a vote != final result
        uint128 rewardPerRound; // extra from the pool reward fund, split among coherent jurors
    }

    uint64 public immutable timelock;
    address public factory;
    address public runnerPool;

    Constitution[] internal _constitutions;
    mapping(uint32 => Lane[]) internal _lanes;
    Params[] internal _params;
    Params internal _pendingParams;
    uint64 public pendingParamsEta;
    mapping(address => uint64) public arbitrationActiveAt;

    event Wired(address factory, address runnerPool);
    event ConstitutionProposed(uint32 indexed id, uint64 activeAt, bytes32 hash);
    event ConstitutionRevoked(uint32 indexed id);
    event ParamsProposed(uint64 eta);
    event ParamsActivated(uint32 indexed id);
    event ArbitrationProposed(address arbitration, uint64 activeAt);

    error Config();
    error Timelocked();

    constructor(
        address owner_,
        uint64 timelock_,
        Params memory genesisParams,
        Constitution memory genesis,
        Lane[] memory genesisLanes,
        address[] memory genesisArbitrations
    ) Ownable(owner_) {
        if (timelock_ < MIN_TIMELOCK) revert Config();
        timelock = timelock_;
        _validate(genesisParams);
        _params.push(genesisParams);
        emit ParamsActivated(0);
        _addConstitution(genesis, genesisLanes, uint64(block.timestamp));
        for (uint256 i; i < genesisArbitrations.length; ++i) {
            if (genesisArbitrations[i].code.length == 0) revert Config();
            arbitrationActiveAt[genesisArbitrations[i]] = uint64(block.timestamp);
            emit ArbitrationProposed(genesisArbitrations[i], uint64(block.timestamp));
        }
    }

    function wire(address factory_, address runnerPool_) external onlyOwner {
        if (factory != address(0) || factory_.code.length == 0 || runnerPool_.code.length == 0) revert Config();
        factory = factory_;
        runnerPool = runnerPool_;
        emit Wired(factory_, runnerPool_);
    }

    // ---------------------------------------------------------------- constitutions

    function proposeConstitution(Constitution calldata c, Lane[] calldata lanes_) external onlyOwner returns (uint32) {
        return _addConstitution(c, lanes_, uint64(block.timestamp) + timelock);
    }

    function _addConstitution(Constitution memory c, Lane[] memory lanes_, uint64 activeAt) internal returns (uint32 id) {
        if (c.promptTemplateHash == 0 || c.rubricHash == 0 || c.schemaHash == 0 || lanes_.length == 0 || lanes_.length > MAX_LANES) {
            revert Config();
        }
        id = uint32(_constitutions.length);
        for (uint256 i; i < lanes_.length; ++i) {
            if (lanes_[i].model == 0 || lanes_[i].provider == 0) revert Config();
            for (uint256 j; j < i; ++j) if (lanes_[j].provider == lanes_[i].provider) revert Config(); // distinct providers
            _lanes[id].push(lanes_[i]);
        }
        c.activeAt = activeAt;
        c.revoked = false;
        _constitutions.push(c);
        emit ConstitutionProposed(id, activeAt, constitutionHash(id));
    }

    /// @notice Immediate, only blocks new seats (running cases keep their constitution).
    function revokeConstitution(uint32 id) external onlyOwner {
        _constitutions[id].revoked = true;
        emit ConstitutionRevoked(id);
    }

    function isConstitutionActive(uint32 id) public view returns (bool) {
        if (id >= _constitutions.length) return false;
        Constitution storage c = _constitutions[id];
        return !c.revoked && block.timestamp >= c.activeAt;
    }

    function constitution(uint32 id) external view returns (Constitution memory) { return _constitutions[id]; }
    function lanes(uint32 id) external view returns (Lane[] memory) { return _lanes[id]; }
    function laneCount(uint32 id) external view returns (uint256) { return _lanes[id].length; }

    /// @notice What runners must reproduce off-chain: prompt/rubric/schema/decoding + the (model, provider) lanes.
    function constitutionHash(uint32 id) public view returns (bytes32) {
        Constitution storage c = _constitutions[id];
        return keccak256(abi.encode(c.promptTemplateHash, c.rubricHash, c.schemaHash, c.decodingHash, _lanes[id]));
    }

    // ---------------------------------------------------------------- params

    function proposeParams(Params calldata p) external onlyOwner {
        _validate(p);
        _pendingParams = p;
        pendingParamsEta = uint64(block.timestamp) + timelock;
        emit ParamsProposed(pendingParamsEta);
    }

    function activateParams() external {
        if (pendingParamsEta == 0 || block.timestamp < pendingParamsEta) revert Timelocked();
        _params.push(_pendingParams);
        delete _pendingParams;
        pendingParamsEta = 0;
        emit ParamsActivated(uint32(_params.length - 1));
    }

    function currentParamsId() external view returns (uint32) { return uint32(_params.length - 1); }
    function getParams(uint32 id) external view returns (Params memory) { return _params[id]; }

    /// @notice openCase -> last executable moment: 3 full rounds + 2 appeal windows + safety margin.
    function worstCaseDuration(uint32 id) public view returns (uint256) {
        Params storage p = _params[id];
        uint256 round = uint256(p.vrfTimeout) + p.commitWindow + p.revealWindow;
        return 3 * round + 2 * uint256(p.appealWindow) + p.safetyMargin;
    }

    // ---------------------------------------------------------------- Azzle modules

    function proposeArbitration(address arbitration) external onlyOwner {
        if (arbitration.code.length == 0 || arbitrationActiveAt[arbitration] != 0) revert Config();
        arbitrationActiveAt[arbitration] = uint64(block.timestamp) + timelock;
        emit ArbitrationProposed(arbitration, arbitrationActiveAt[arbitration]);
    }

    function isSupportedArbitration(address arbitration) external view returns (bool) {
        uint64 at = arbitrationActiveAt[arbitration];
        return at != 0 && block.timestamp >= at;
    }

    function _validate(Params memory p) internal pure {
        uint8 prev;
        for (uint256 i; i < 3; ++i) {
            uint8 n = p.jurySizes[i];
            if (n == 0 || n > 15 || n % 2 == 0 || n < prev) revert Config();
            prev = n;
        }
        if (
            p.vrfTimeout == 0 || p.commitWindow == 0 || p.revealWindow == 0 || p.minProviders == 0
                || p.minProviders > MAX_LANES || p.minProviders > p.jurySizes[0]
        ) revert Config();
    }
}
