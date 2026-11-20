// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {BotledCageV5Near} from "./BotledCageV5Near.sol";
import {BotledConfig} from "../BotledConfig.sol";
import {INearConfig} from "./interfaces/IBotledNear.sol";

interface IRulingWindowV5N {
    function rulingWindow() external view returns (uint64);
}

interface IPoolAnchorN {
    function config() external view returns (address);
}

/// @title Botled v5/NEAR — cage factory, provenance registry and RunnerPoolNear trust anchor
/// @notice Same pattern as BotledFactoryV5: EIP-1167 clones of one immutable implementation, CREATE2 salt bound to
///         the caller, no admin. Reuses the deployed BotledConfig (params, supported Azzle modules) and adds the
///         timelocked BotledNearConfig (NEAR AI keys, request templates = "constitutions" in NEAR form).
contract BotledFactoryV5Near {
    BotledConfig public immutable config;
    INearConfig public immutable nearConfig;
    address public immutable pool;
    address public immutable panelOwner;
    address public immutable implementation;
    mapping(address => bool) public isCage;
    address[] public cages;

    event CageDeployed(address indexed cage, address indexed operator, uint32 templateId);

    error Unsupported();
    error Anchor();

    constructor(
        BotledConfig config_,
        INearConfig nearConfig_,
        address verifier_,
        address pool_,
        address panelOwner_,
        address microScope_,
        address standardScope_
    ) {
        if (IPoolAnchorN(pool_).config() != address(this)) revert Anchor();
        config = config_;
        nearConfig = nearConfig_;
        pool = pool_;
        panelOwner = panelOwner_;
        implementation = address(
            new BotledCageV5Near(
                address(config_), address(nearConfig_), verifier_, pool_, address(this), panelOwner_, microScope_, standardScope_
            )
        );
    }

    function factory() external view returns (address) { return address(this); }

    function deployCage(uint32 templateId, bytes32 salt) external returns (address cage) {
        BotledCageV5Near impl = BotledCageV5Near(payable(implementation));
        address micro = address(impl.micro());
        address standard = address(impl.standard());
        if (!config.isSupportedArbitration(micro) || !config.isSupportedArbitration(standard) || !nearConfig.isTemplateActive(templateId)) {
            revert Unsupported();
        }
        uint32 pid = config.currentParamsId();
        uint256 worst = config.worstCaseDuration(pid);
        if (
            config.getParams(pid).minProviders > nearConfig.laneCount(templateId)
                || worst > IRulingWindowV5N(micro).rulingWindow() || worst > IRulingWindowV5N(standard).rulingWindow()
        ) revert Unsupported();
        cage = Clones.cloneDeterministic(implementation, keccak256(abi.encode(msg.sender, salt)));
        BotledCageV5Near(payable(cage)).initialize(templateId, msg.sender);
        isCage[cage] = true;
        cages.push(cage);
        emit CageDeployed(cage, msg.sender, templateId);
    }

    function predictCage(address deployer, bytes32 salt) external view returns (address) {
        return Clones.predictDeterministicAddress(implementation, keccak256(abi.encode(deployer, salt)));
    }

    function cageCount() external view returns (uint256) { return cages.length; }

    function allCages() external view returns (address[] memory) { return cages; }
}
