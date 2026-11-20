// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {BotledCageV5} from "./BotledCageV5.sol";
import {BotledConfig} from "../BotledConfig.sol";

interface IRulingWindowV5 {
    function rulingWindow() external view returns (uint64);
}

interface IPoolTrustAnchor {
    function config() external view returns (address);
}

/// @title Botled v5 — cage factory, provenance registry and RunnerPool trust anchor
/// @notice Deploys EIP-1167 clones of one immutable BotledCageV5 implementation via CREATE2 (salt bound to
///         the caller). Clones have no admin and no upgrade path.
/// @dev Reuses the deployed BotledConfig (constitutions, lanes, timelocked params). The deployed v4 config
///      can only be wired once (to the v4 factory + v4 pool), so v5 runs its own, unmodified BotledRunnerPool
///      whose `config` slot points at THIS factory: the pool's trust check
///      `IBotledFactoryView(IBotledConfigView(config).factory()).isCage(msg.sender)` resolves to
///      `this.factory() == this` -> `this.isCage(msg.sender)`. The constructor refuses any pool that is not
///      anchored here, so no other contract can ever request draws or settle slashes in that pool.
contract BotledFactoryV5 {
    BotledConfig public immutable config;
    address public immutable pool;
    address public immutable panelOwner;
    address public immutable implementation;
    mapping(address => bool) public isCage;
    address[] public cages;

    event CageDeployed(address indexed cage, address indexed operator, uint32 constitutionId);

    error Unsupported();
    error Anchor();

    constructor(BotledConfig config_, address pool_, address panelOwner_, address microScope_, address standardScope_) {
        if (IPoolTrustAnchor(pool_).config() != address(this)) revert Anchor();
        config = config_;
        pool = pool_;
        panelOwner = panelOwner_;
        implementation =
            address(new BotledCageV5(address(config_), pool_, address(this), panelOwner_, microScope_, standardScope_));
    }

    /// @notice Pool trust anchor: the pool asks `config.factory()`; for the v5 pool `config` is this factory.
    function factory() external view returns (address) { return address(this); }

    function deployCage(uint32 constitutionId, bytes32 salt) external returns (address cage) {
        BotledCageV5 impl = BotledCageV5(payable(implementation));
        address micro = address(impl.micro());
        address standard = address(impl.standard());
        if (
            !config.isSupportedArbitration(micro) || !config.isSupportedArbitration(standard)
                || !config.isConstitutionActive(constitutionId)
        ) revert Unsupported();
        uint32 pid = config.currentParamsId();
        uint256 worst = config.worstCaseDuration(pid);
        if (
            config.getParams(pid).minProviders > config.laneCount(constitutionId)
                || worst > IRulingWindowV5(micro).rulingWindow() || worst > IRulingWindowV5(standard).rulingWindow()
        ) revert Unsupported();
        cage = Clones.cloneDeterministic(implementation, keccak256(abi.encode(msg.sender, salt)));
        BotledCageV5(payable(cage)).initialize(constitutionId, msg.sender);
        isCage[cage] = true;
        cages.push(cage);
        emit CageDeployed(cage, msg.sender, constitutionId);
    }

    function predictCage(address deployer, bytes32 salt) external view returns (address) {
        return Clones.predictDeterministicAddress(implementation, keccak256(abi.encode(deployer, salt)));
    }

    function cageCount() external view returns (uint256) { return cages.length; }

    function allCages() external view returns (address[] memory) { return cages; }
}
