// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {ArbitrationModuleV2} from "azzle-v2/ArbitrationModuleV2.sol";
import {VerifierBondVaultV2} from "azzle-v2/VerifierBondVaultV2.sol";
import {BotledPanelOwner, IPanelModule} from "../src/botled/BotledPanelOwner.sol";
import {BotledConfig} from "../src/botled/BotledConfig.sol";
import {BotledRunnerPoolNear} from "../src/botled/v5near/BotledRunnerPoolNear.sol";
import {BotledCageV5Near} from "../src/botled/v5near/BotledCageV5Near.sol";
import {BotledFactoryV5Near} from "../src/botled/v5near/BotledFactoryV5Near.sol";
import {INearConfig} from "../src/botled/v5near/interfaces/IBotledNear.sol";
import {AZL, MockTreasury, MockEscrow, MockRep, MockRegistry, MockVrfWrapper} from "../test/Botled.t.sol";
import {NearFixtures} from "../test/near/NearFixtures.sol";

/// @notice LOCAL ANVIL ONLY (refuses any other chain id): full v5/NEAR stack with Azzle v2 modules + mocks for the
///         runner-near end-to-end test. All keys are public test constants passed in by runner-near/e2e.ts.
contract DeployLocalNear is Script {
    struct TemplateT {
        bytes32 systemPromptHash;
        bytes32 rubricHash;
        uint64 activeAt;
    }

    function _lane(bytes memory model, bytes32 provider, uint8 kind, bytes memory sys, bytes memory schema)
        internal
        pure
        returns (INearConfig.Lane memory)
    {
        bytes memory h = NearFixtures.head(model, sys);
        bytes memory t = NearFixtures.tail(NearFixtures.laneMaxTokens(model), schema);
        return INearConfig.Lane(model, provider, keccak256(h), keccak256(t), uint32(h.length), uint32(t.length), kind);
    }

    /// @dev legacy-profile artifacts link the SCL ed25519 library; scripts don't auto-link deployCode artifacts.
    ///      placeholder = "__$" + keccak256("src/vendor/scl/src/lib/libSCL_EIP6565.sol:SCL_EIP6565")[0:17] + "$__"
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

    AZL token;
    MockRegistry reg;
    MockVrfWrapper vrf;
    ArbitrationModuleV2 micro;
    ArbitrationModuleV2 standard;
    BotledPanelOwner po;
    BotledConfig config;
    address nearCfg;
    address verifier;
    BotledRunnerPoolNear pool;
    BotledCageV5Near cage;
    address me;

    function run() external {
        require(block.chainid == 31337, "local anvil only");
        uint256 pk = vm.envUint("E2E_DEPLOYER_PK"); // anvil account #0 (public test key)
        me = vm.addr(pk);
        vm.startBroadcast(pk);
        _azzle();
        _config();
        _near();
        _pool();
        vm.stopBroadcast();
        _write();
    }

    function _azzle() internal {
        token = new AZL();
        MockTreasury tr = new MockTreasury();
        reg = new MockRegistry();
        vrf = new MockVrfWrapper();
        VerifierBondVaultV2 mv = new VerifierBondVaultV2(address(token), 1_000e18, 7 days, address(tr), me);
        VerifierBondVaultV2 sv = new VerifierBondVaultV2(address(token), 10_000e18, 7 days, address(tr), me);
        micro = new ArbitrationModuleV2(address(reg), address(new MockEscrow()), address(new MockRep()), address(mv), address(tr), 3 days, 2 days, 1000, new address[](0), me);
        standard = new ArbitrationModuleV2(address(reg), address(new MockEscrow()), address(new MockRep()), address(sv), address(tr), 3 days, 2 days, 1000, new address[](0), me);
        mv.configureArbitration(address(micro));
        sv.configureArbitration(address(standard));
        po = new BotledPanelOwner(me, IPanelModule(address(micro)), IPanelModule(address(standard)), 0.002 ether, 128, address(0));
        micro.transferOwnership(address(po));
        standard.transferOwnership(address(po));
        po.acceptModuleOwnership();
    }

    function _config() internal {
        BotledConfig.Params memory p;
        p.jurySizes = [uint8(3), 7, 15];
        p.minProviders = 2;
        p.vrfTimeout = 1 hours;
        p.commitWindow = 3 hours;
        p.revealWindow = 2 hours;
        p.appealWindow = 6 hours;
        p.safetyMargin = 2 hours;
        p.appealBonds = [uint128(200e18), uint128(400e18)];
        p.rewardPerRound = 30e18;
        BotledConfig.Lane[] memory l4 = new BotledConfig.Lane[](2);
        l4[0] = BotledConfig.Lane(bytes32("unused-a"), bytes32("a"));
        l4[1] = BotledConfig.Lane(bytes32("unused-b"), bytes32("b"));
        BotledConfig.Constitution memory c4;
        (c4.promptTemplateHash, c4.rubricHash, c4.schemaHash, c4.decodingHash) = (keccak256("p"), keccak256("r"), keccak256("s"), keccak256("d"));
        address[] memory arbs = new address[](2);
        (arbs[0], arbs[1]) = (address(micro), address(standard));
        config = new BotledConfig(me, 1 days, p, c4, l4, arbs);
    }

    function _near() internal {
        bytes memory sys = bytes(vm.readFile("test/near-vectors/system_prompt.txt"));
        bytes memory schema = bytes(vm.readFile("test/near-vectors/schema.compact.json"));
        INearConfig.Signer[] memory s = new INearConfig.Signer[](4);
        (s[0].scheme, s[0].kind, s[0].ecdsa) = (1, 1, vm.envAddress("E2E_GATEWAY"));
        (s[1].scheme, s[1].kind, s[1].ecdsa, s[1].modelHash) = (1, 2, vm.envAddress("E2E_TEE"), keccak256(NearFixtures.DEEPSEEK));
        (s[2].scheme, s[2].kind, s[2].ecdsa) = (1, 3, vm.envAddress("E2E_SPONSOR"));
        (s[3].scheme, s[3].kind, s[3].ecdsa) = (1, 3, vm.envAddress("E2E_SPONSOR_B")); // 2nd independent relay
        INearConfig.Lane[] memory lanes = new INearConfig.Lane[](2);
        lanes[0] = _lane(NearFixtures.KIMI, "moonshotai", 1, sys, schema);
        lanes[1] = _lane(NearFixtures.DEEPSEEK, "deepseek", 2, sys, schema);
        address scl = _create(vm.parseBytes(vm.parseJsonString(vm.readFile("out/libSCL_EIP6565.sol/SCL_EIP6565.json"), ".bytecode.object")));
        nearCfg = _create(abi.encodePacked(
            _linked("BotledNearConfig", scl),
            abi.encode(me, uint64(1 days), s, TemplateT(keccak256(sys), keccak256("rubric"), 0), lanes, vm.envAddress("E2E_ENROLL"))
        ));
        verifier = _create(abi.encodePacked(_linked("BotledNearVerifier", scl), abi.encode(nearCfg)));
    }

    function _pool() internal {
        address predicted = vm.computeCreateAddress(me, vm.getNonce(me) + 1);
        pool = new BotledRunnerPoolNear(predicted, nearCfg, address(token), address(vrf), 4, 100_000, 70_000, 3);
        BotledFactoryV5Near factory = new BotledFactoryV5Near(config, INearConfig(nearCfg), verifier, address(pool), address(po), address(0), address(0));
        require(address(factory) == predicted, "anchor");
        (bool ok,) = address(pool).call{value: 1 ether}("");
        require(ok);
        token.mint(me, 20_000e18);
        token.approve(address(pool), 1_000e18);
        pool.fundRewards(1_000e18);
        cage = BotledCageV5Near(payable(factory.deployCage(0, "e2e")));
        token.approve(address(cage), 11_000e18);
        cage.seat{value: 0.002 ether}(0, 0);
    }

    function _write() internal {
        string memory o = "e2e";
        vm.serializeAddress(o, "registry", address(reg));
        vm.serializeAddress(o, "vrf", address(vrf));
        vm.serializeAddress(o, "micro", address(micro));
        vm.serializeAddress(o, "standard", address(standard));
        vm.serializeAddress(o, "nearConfig", nearCfg);
        vm.serializeAddress(o, "verifier", verifier);
        vm.serializeAddress(o, "pool", address(pool));
        vm.serializeAddress(o, "token", address(token));
        string memory out = vm.serializeAddress(o, "cage", address(cage));
        vm.writeJson(out, "runner-near/e2e/deployment.json");
    }
}
