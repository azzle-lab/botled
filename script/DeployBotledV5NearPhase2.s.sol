// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

interface IPoolV {
    function config() external view returns (address);
    function factory() external view returns (address);
    function nearConfig() external view returns (address);
    function rewardToken() external view returns (address);
    function maxConcurrent() external view returns (uint32);
}

interface IFactoryV {
    function config() external view returns (address);
    function nearConfig() external view returns (address);
    function pool() external view returns (address);
    function panelOwner() external view returns (address);
    function implementation() external view returns (address);
}

interface ICageV {
    function config() external view returns (address);
    function nearConfig() external view returns (address);
    function verifier() external view returns (address);
    function pool() external view returns (address);
    function factory() external view returns (address);
    function operator() external view returns (address);
}

/// @notice Botled v5/NEAR phase 2 on BASE MAINNET: BotledRunnerPoolNear + BotledFactoryV5Near in two consecutive
///         CREATEs from the deployer (pool anchor = factory address predicted from the live nonce). The factory
///         constructor deploys the BotledCageV5Near implementation, linked to the phase-1 libraries. No deployCage.
contract DeployBotledV5NearPhase2 is Script {
    address constant DEPLOYER = 0x3D5eb1F648F495fAEFaeBa0dE74A5c52b6602F5D;
    address constant CONFIG = 0x6A5785cc5e79Dc4c800367b54eA525c5e31040D7; // existing BotledConfig (read-only use)
    address constant PANEL_OWNER = 0xF7E5A611154C8d30A03791409F2606C278597a04;
    address constant AZL = 0x931517E9502F9d52CDF6F5AC7fca7925e2A1BBA3;
    address constant VRF_WRAPPER = 0xb0407dbe851f8318bd31404A49e658143C982F23;
    address constant NEAR_CONFIG = 0xAdb89C4fb606d346BA62F58C4B0e0F47c3e9F20a;
    address constant VERIFIER = 0x5B649acd02838b33777FdBaEe49D9FC405A62483;
    address constant CAGE_SEAT = 0x3DD3443ea1712CA30a9797Ea4DFD341641CEa5F1;
    address constant CAGE_VOTES = 0x90dfe90aC041aB64d7302282885144605bedfA94;
    address constant CAGE_SETTLE = 0x404864C55e883D9b74be6FDfF5cFBcCD18d8fB58;

    function _hex(address a) internal pure returns (string memory) {
        return vm.toLowercase(vm.replace(vm.toString(a), "0x", ""));
    }

    function _factoryCode() internal view returns (bytes memory) {
        string memory o = vm.parseJsonString(vm.readFile("out/BotledFactoryV5Near.sol/BotledFactoryV5Near.json"), ".bytecode.object");
        o = vm.replace(o, "__$71e41522daa6ecaeb454e1e95f3d111344$__", _hex(CAGE_SEAT));
        o = vm.replace(o, "__$2709dea1536c286e09451ce9db9464864b$__", _hex(CAGE_VOTES));
        o = vm.replace(o, "__$991a031b5cc253f28f78eb098b9798ed0a$__", _hex(CAGE_SETTLE));
        return vm.parseBytes(o); // reverts if any placeholder is left
    }

    function _poolCode() internal view returns (bytes memory) {
        return vm.parseBytes(vm.parseJsonString(vm.readFile("out/BotledRunnerPoolNear.sol/BotledRunnerPoolNear.json"), ".bytecode.object"));
    }

    function _create(bytes memory code) internal returns (address a) {
        assembly ("memory-safe") {
            a := create(0, add(code, 0x20), mload(code))
        }
        require(a != address(0), "create");
    }

    function run() external {
        require(block.chainid == 8453, "base mainnet only");
        uint256 pk = vm.envUint("BOTLED_PK");
        require(vm.addr(pk) == DEPLOYER, "deployer");
        bytes memory fcode = _factoryCode();
        bytes memory pcode = _poolCode();
        uint64 n = vm.getNonce(DEPLOYER);
        address predicted = vm.computeCreateAddress(DEPLOYER, n + 1);
        console2.log("deployer nonce", n);

        vm.startBroadcast(pk);
        // same VRF economics as v4/v5: callback 100k + 70k/juror, 3 confirmations; 4 parallel draws per runner
        address pool = _create(abi.encodePacked(pcode, abi.encode(predicted, NEAR_CONFIG, AZL, VRF_WRAPPER, uint32(4), uint32(100_000), uint32(70_000), uint16(3))));
        address factory = _create(abi.encodePacked(fcode, abi.encode(CONFIG, NEAR_CONFIG, VERIFIER, pool, PANEL_OWNER, address(0), address(0))));
        vm.stopBroadcast();

        require(factory == predicted, "factory != anchor");
        IPoolV p = IPoolV(pool);
        IFactoryV f = IFactoryV(factory);
        require(p.config() == factory && p.factory() == factory && p.nearConfig() == NEAR_CONFIG && p.rewardToken() == AZL, "pool");
        require(f.pool() == pool && f.config() == CONFIG && f.nearConfig() == NEAR_CONFIG && f.panelOwner() == PANEL_OWNER, "factory");
        ICageV impl = ICageV(f.implementation());
        require(impl.pool() == pool && impl.factory() == factory && impl.verifier() == VERIFIER && impl.nearConfig() == NEAR_CONFIG
            && impl.config() == CONFIG && impl.operator() == address(1), "impl");
        console2.log("BotledRunnerPoolNear :", pool);
        console2.log("BotledFactoryV5Near  :", factory);
        console2.log("BotledCageV5Near impl:", f.implementation());
    }
}
