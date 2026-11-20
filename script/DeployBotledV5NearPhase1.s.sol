// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {INearConfig} from "../src/botled/v5near/interfaces/IBotledNear.sol";
import {NearFixtures} from "../test/near/NearFixtures.sol";

interface INearCfgView {
    function owner() external view returns (address);
    function timelock() external view returns (uint64);
    function enrollSigner() external view returns (address);
    function signerCount() external view returns (uint256);
    function laneCount(uint32) external view returns (uint256);
    function isTemplateActive(uint32) external view returns (bool);
    function isSignerActive(uint32) external view returns (bool);
}

interface IVerifierView {
    function config() external view returns (address);
}

/// @notice Botled v5/NEAR phase 1 on BASE MAINNET (chain 8453): only the parts that do not depend on the standard
///         arbitration module unlock: SCL_EIP6565 (ed25519) library, the three linked cage libraries (CageSeat,
///         CageVotes, CageSettle; linked into the cage implementation that BotledFactoryV5Near deploys later),
///         BotledNearConfig (genesis keys + template) and the stateless BotledNearVerifier.
///         NOT deployed here: BotledRunnerPoolNear (its immutable `factory` anchor must be the factory's address, so
///         pool + factory are deployed together in consecutive nonces), the factory and any cage.
///   simulate : forge script script/DeployBotledV5NearPhase1.s.sol --fork-url $BASE_RPC
///   broadcast: add --broadcast (BOTLED_PK from the deployer key file, never printed)
contract DeployBotledV5NearPhase1 is Script {
    struct TemplateT {
        bytes32 systemPromptHash;
        bytes32 rubricHash;
        uint64 activeAt;
    }

    // NEAR AI keys, re-attested 2026-11-20 (runner-near/attestation-pins.json, deploy/attestation-mainnet-20261120.json)
    address constant GW_ECDSA = 0xb98A789Cdc4817275F5155593ba73EF2a957e779;
    uint256 constant GW_ED = 0x40599fb284f43953bb356b09080fd803c960fc10285ad90eca462ca711ad4acb;
    uint256 constant GW_WX = 42676130079551593973673125876230518046791080229428114621746360344985801889187;
    uint256 constant GW_WY = 35291603471346667703562426432940291986318014996113700382611454260910592915546;
    address constant DS_ECDSA = 0xfe0071895500A9755C18044948AB4f4e1A7f337e;
    uint256 constant DS_ED = 0x236f5a6b91dd47dc3b7b36e43d4eb531a042ffb8f8fbf3a1555b78cef4fdda4c;
    uint256 constant DS_WX = 17434810981884461409275962346463205779709739437501424370853330652094074868461;
    uint256 constant DS_WY = 22810675813067226280537522601436914280248282412383173995532820579254066382470;
    // Botled sponsor relays (keys in /home/box/secrets/botled-relay-{a,b}.json)
    address constant SPONSOR_A = 0x893DE9AAbd116E501Fe46466DF830251497FBdA7;
    address constant SPONSOR_B = 0x9Aa579Bcef7F8836CBF55bAfA4aceA69F1721cF6;
    // v1.signer derived address for (b0c3f8cb…c625, "botled-enroll-v1"), checked against v1.signer.derived_public_key
    address constant ENROLL = 0x7dd9b26E03E355D2C59e972A355C9303B8d1Dd94;

    function _lane(bytes memory model, bytes32 provider, uint8 kind, bytes memory sys, bytes memory schema)
        internal
        pure
        returns (INearConfig.Lane memory)
    {
        bytes memory h = NearFixtures.head(model, sys);
        bytes memory t = NearFixtures.tail(NearFixtures.laneMaxTokens(model), schema);
        return INearConfig.Lane(model, provider, keccak256(h), keccak256(t), uint32(h.length), uint32(t.length), kind);
    }

    function _code(string memory file, string memory name) internal view returns (bytes memory) {
        return vm.parseBytes(vm.parseJsonString(vm.readFile(string.concat("out/", file, "/", name, ".json")), ".bytecode.object"));
    }

    function _linked(string memory name, address lib) internal view returns (bytes memory) {
        string memory obj =
            vm.parseJsonString(vm.readFile(string.concat("out/", name, ".sol/", name, ".json")), ".bytecode.object");
        string memory hexAddr = vm.replace(vm.toString(lib), "0x", "");
        return vm.parseBytes(vm.replace(obj, "__$7027f903e030e084697e3e5e3808091548$__", vm.toLowercase(hexAddr)));
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
        address me = vm.addr(pk);
        require(me == 0x3D5eb1F648F495fAEFaeBa0dE74A5c52b6602F5D, "deployer");
        bytes memory sys = bytes(vm.readFile("test/near-vectors/system_prompt.txt"));
        bytes memory schema = bytes(vm.readFile("test/near-vectors/schema.compact.json"));

        INearConfig.Signer[] memory s = new INearConfig.Signer[](6);
        (s[0].scheme, s[0].kind, s[0].ecdsa) = (1, 1, GW_ECDSA); // 0 gateway ecdsa (kimi lane default)
        (s[1].scheme, s[1].kind, s[1].edKey) = (2, 1, [GW_WX, GW_WY, 0, 0, GW_ED]); // 1 gateway ed25519 fallback
        (s[2].scheme, s[2].kind, s[2].ecdsa, s[2].modelHash) = (1, 2, DS_ECDSA, keccak256(NearFixtures.DEEPSEEK)); // 2
        (s[3].scheme, s[3].kind, s[3].edKey, s[3].modelHash) =
            (2, 2, [DS_WX, DS_WY, 0, 0, DS_ED], keccak256(NearFixtures.DEEPSEEK)); // 3 DeepSeek TEE ed25519 fallback
        (s[4].scheme, s[4].kind, s[4].ecdsa) = (1, 3, SPONSOR_A); // 4 sponsor relay A
        (s[5].scheme, s[5].kind, s[5].ecdsa) = (1, 3, SPONSOR_B); // 5 sponsor relay B
        INearConfig.Lane[] memory lanes = new INearConfig.Lane[](2);
        lanes[0] = _lane(NearFixtures.KIMI, "moonshotai", 1, sys, schema);
        lanes[1] = _lane(NearFixtures.DEEPSEEK, "deepseek", 2, sys, schema);
        // rubricHash (documentation only): keccak256 of the compact JSON response schema
        TemplateT memory t = TemplateT(keccak256(sys), keccak256(schema), 0);

        vm.startBroadcast(pk);
        address scl = _create(_code("libSCL_EIP6565.sol", "SCL_EIP6565"));
        address cageSeat = _create(_code("CageSeat.sol", "CageSeat"));
        address cageVotes = _create(_code("CageVotes.sol", "CageVotes"));
        address cageSettle = _create(_code("CageSettle.sol", "CageSettle"));
        address nearCfg = _create(abi.encodePacked(_linked("BotledNearConfig", scl), abi.encode(me, uint64(1 days), s, t, lanes, ENROLL)));
        address verifier = _create(abi.encodePacked(_linked("BotledNearVerifier", scl), abi.encode(nearCfg)));
        vm.stopBroadcast();

        INearCfgView c = INearCfgView(nearCfg);
        require(c.owner() == me && c.timelock() == 1 days && c.enrollSigner() == ENROLL, "cfg");
        require(c.signerCount() == 6 && c.laneCount(0) == 2 && c.isTemplateActive(0), "cfg2");
        for (uint32 i; i < 6; ++i) require(c.isSignerActive(i), "signer");
        console2.log("SCL_EIP6565        :", scl);
        console2.log("CageSeat           :", cageSeat);
        console2.log("CageVotes          :", cageVotes);
        console2.log("CageSettle         :", cageSettle);
        console2.log("BotledNearConfig   :", nearCfg);
        console2.log("BotledNearVerifier :", verifier);
        console2.logBytes32(lanes[0].headHash);
        console2.logBytes32(lanes[0].tailHash);
        console2.logBytes32(lanes[1].headHash);
        console2.logBytes32(lanes[1].tailHash);
        console2.logBytes32(t.systemPromptHash);
        console2.logBytes32(t.rubricHash);
    }
}
