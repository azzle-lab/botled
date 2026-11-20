// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {BotledArbitrator} from "./BotledArbitrator.sol";
import {BotledConfig} from "./BotledConfig.sol";

interface IRulingWindow {
    function rulingWindow() external view returns (uint64);
}

/// @title Botled v4 — seat factory and provenance registry
/// @notice Deploys EIP-1167 clones of one immutable BotledArbitrator implementation via CREATE2
///         (salt bound to the caller). Clones have no admin and no upgrade path.
contract BotledFactory {
    BotledConfig public immutable config;
    address public immutable pool;
    address public immutable implementation;
    mapping(address => bool) public isCage;
    address[] public cages;

    event CageDeployed(address indexed cage, address indexed arbitration, address indexed operator, uint32 constitutionId);

    error Unsupported();

    constructor(BotledConfig config_, address pool_, address scopeRegistry_) {
        config = config_;
        pool = pool_;
        implementation = address(new BotledArbitrator(address(config_), pool_, address(this), scopeRegistry_));
    }

    function deployCage(address arbitration, uint32 constitutionId, bytes32 salt) external returns (address cage) {
        // live only once the config is wired to exactly this factory + pool
        if (config.factory() != address(this) || config.runnerPool() != pool) revert Unsupported();
        if (!config.isSupportedArbitration(arbitration) || !config.isConstitutionActive(constitutionId)) revert Unsupported();
        uint32 pid = config.currentParamsId();
        // lane diversity must be satisfiable, and every round incl. appeals must fit the module's rulingWindow
        if (
            config.getParams(pid).minProviders > config.laneCount(constitutionId)
                || config.worstCaseDuration(pid) > IRulingWindow(arbitration).rulingWindow()
        ) revert Unsupported();
        cage = Clones.cloneDeterministic(implementation, keccak256(abi.encode(msg.sender, salt)));
        BotledArbitrator(payable(cage)).initialize(arbitration, constitutionId, msg.sender);
        isCage[cage] = true;
        cages.push(cage);
        emit CageDeployed(cage, arbitration, msg.sender, constitutionId);
    }

    function predictCage(address deployer, bytes32 salt) external view returns (address) {
        return Clones.predictDeterministicAddress(implementation, keccak256(abi.encode(deployer, salt)));
    }

    function cageCount() external view returns (uint256) { return cages.length; }

    /// @notice Optional Azzle-side admission policy hook (azzle-optional/PanelJoinGateV2).
    function admits(address member, address arbitration) external view returns (bool) {
        return isCage[member] && address(BotledArbitrator(payable(member)).arbitration()) == arbitration;
    }
}
