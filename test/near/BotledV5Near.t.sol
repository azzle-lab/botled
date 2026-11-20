// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ArbitrationModuleV2} from "azzle-v2/ArbitrationModuleV2.sol";
import {VerifierBondVaultV2} from "azzle-v2/VerifierBondVaultV2.sol";
import {BotledPanelOwner, IPanelModule} from "../../src/botled/BotledPanelOwner.sol";
import {BotledConfig} from "../../src/botled/BotledConfig.sol";
import {BotledRunnerPoolNear} from "../../src/botled/v5near/BotledRunnerPoolNear.sol";
import {BotledCageV5Near} from "../../src/botled/v5near/BotledCageV5Near.sol";
import {BotledFactoryV5Near} from "../../src/botled/v5near/BotledFactoryV5Near.sol";
import {INearConfig, INearVerifier} from "../../src/botled/v5near/interfaces/IBotledNear.sol";
import {JsonText} from "../../src/botled/v5near/lib/JsonText.sol";
import {IAzzleArbitrationV2} from "../../src/botled/interfaces/IAzzle.sol";
import {AZL, MockTreasury, MockEscrow, MockRep, MockRegistry, MockVrfWrapper} from "../Botled.t.sol";
import {NearFixtures} from "./NearFixtures.sol";

interface IEdSigner {
    function extKey() external view returns (uint256[5] memory);
    function sign(bytes calldata text) external view returns (bytes memory);
}

/// @notice End-to-end v5/NEAR flows on real Azzle ArbitrationModuleV2 + VerifierBondVaultV2 + BotledPanelOwner:
///         enrollment tickets (simulated MPC key), relayed commits, receipt-backed reveals, no-show suspension.
contract BotledV5NearTest is Test {
    struct TemplateT {
        bytes32 systemPromptHash;
        bytes32 rubricHash;
        uint64 activeAt;
    }

    uint256 constant PFAND = 0.002 ether;
    uint256 constant GATEWAY_PK = 0x6A7E;       // stands in for NEAR AI gateway ECDSA identity (kimi lane)
    uint256 constant TEE_PK = 0x7EE;            // stands in for the DeepSeek-V4.1-Flash-1017 TEE key (deepseek lane)
    uint256 constant SPONSOR_PK = 0x5905;       // Botled sponsor relay key
    uint256 constant SESSION_OFFSET = 0x1000_0000; // runner session key = runner pk + offset (per ticket in prod)
    uint256 constant ENROLL_PK = 0xE4401;       // stands in for the MPC key derived for (registry.near, path)
    uint256 constant RUNNER_PK0 = 0xB0700;
    bytes constant POSTER_DOC = "Poster: delivery misses the /refund endpoint that the scope requires.";
    bytes constant WORKER_DOC = "Worker: commit 9f2c implements /refund; see tests/refund.spec.ts (41/41 green).\nDeadline met.";

    AZL token;
    IERC20 azl;
    MockRegistry reg;
    MockVrfWrapper vrf;
    ArbitrationModuleV2 micro;
    ArbitrationModuleV2 standard;
    VerifierBondVaultV2 mv;
    VerifierBondVaultV2 sv;
    BotledPanelOwner po;
    BotledConfig config;
    INearConfig nearCfg;
    INearVerifier verifier;
    IEdSigner edSigner;
    BotledRunnerPoolNear pool;
    BotledFactoryV5Near factory;
    BotledCageV5Near cage;
    address safe = makeAddr("safe");
    address operator = makeAddr("operator");
    address keeper = makeAddr("keeper");
    bytes systemPrompt;
    bytes schema;
    mapping(address => uint256) pkOf;
    address[] runners;

    // ================================================================ setup

    function _params() internal pure returns (BotledConfig.Params memory p) {
        p.jurySizes = [uint8(3), 7, 15];
        p.minProviders = 2;
        p.vrfTimeout = 1 hours;
        p.commitWindow = 3 hours;
        p.revealWindow = 2 hours;
        p.appealWindow = 6 hours;
        p.safetyMargin = 2 hours;
        p.appealBonds = [uint128(200e18), uint128(400e18)];
        p.noShowSlash = 50e18;    // ignored by v5/NEAR (no bonds)
        p.minoritySlash = 20e18;  // ignored by v5/NEAR (no minority slash)
        p.rewardPerRound = 30e18;
    }

    function _lane(bytes memory model, bytes32 provider, uint8 kind) internal view returns (INearConfig.Lane memory l) {
        bytes memory h = NearFixtures.head(model, systemPrompt);
        bytes memory t = NearFixtures.tail(NearFixtures.laneMaxTokens(model), schema);
        l = INearConfig.Lane(model, provider, keccak256(h), keccak256(t), uint32(h.length), uint32(t.length), kind);
    }

    function setUp() public {
        systemPrompt = bytes(vm.readFile("test/near-vectors/system_prompt.txt"));
        schema = bytes(vm.readFile("test/near-vectors/schema.compact.json"));
        token = new AZL();
        azl = IERC20(address(token));
        MockTreasury tr = new MockTreasury();
        reg = new MockRegistry();
        vrf = new MockVrfWrapper();
        mv = new VerifierBondVaultV2(address(token), 1_000e18, 7 days, address(tr), safe);
        sv = new VerifierBondVaultV2(address(token), 10_000e18, 7 days, address(tr), safe);
        micro = new ArbitrationModuleV2(address(reg), address(new MockEscrow()), address(new MockRep()), address(mv), address(tr), 3 days, 2 days, 1000, new address[](0), safe);
        standard = new ArbitrationModuleV2(address(reg), address(new MockEscrow()), address(new MockRep()), address(sv), address(tr), 3 days, 2 days, 1000, new address[](0), safe);
        vm.startPrank(safe);
        mv.configureArbitration(address(micro));
        sv.configureArbitration(address(standard));
        vm.stopPrank();
        po = new BotledPanelOwner(safe, IPanelModule(address(micro)), IPanelModule(address(standard)), PFAND, 128, address(0));
        vm.startPrank(safe);
        micro.transferOwnership(address(po));
        standard.transferOwnership(address(po));
        vm.stopPrank();
        po.acceptModuleOwnership();

        // deployed v4 BotledConfig stand-in (params + both modules); its Surplus lanes are NOT used by v5/NEAR
        BotledConfig.Lane[] memory l4 = new BotledConfig.Lane[](2);
        l4[0] = BotledConfig.Lane(bytes32("claude-opus-5"), bytes32("anthropic"));
        l4[1] = BotledConfig.Lane(bytes32("gemini-4-argon"), bytes32("google"));
        BotledConfig.Constitution memory c4;
        (c4.promptTemplateHash, c4.rubricHash, c4.schemaHash, c4.decodingHash) = (keccak256("p"), keccak256("r"), keccak256("s"), keccak256("d"));
        address[] memory arbs = new address[](2);
        (arbs[0], arbs[1]) = (address(micro), address(standard));
        config = new BotledConfig(address(this), 1 days, _params(), c4, l4, arbs);

        // NEAR side of Base: keys + template (legacy-compiled, deployed from artifacts)
        edSigner = IEdSigner(deployCode("Ed25519TestSigner.sol:Ed25519TestSigner", abi.encode(uint256(0x5EED))));
        INearConfig.Signer[] memory s = new INearConfig.Signer[](4);
        (s[0].scheme, s[0].kind, s[0].ecdsa) = (1, 1, vm.addr(GATEWAY_PK)); // primary: ECDSA gateway
        (s[1].scheme, s[1].kind, s[1].edKey) = (2, 1, edSigner.extKey()); // fallback slot: ed25519 gateway
        (s[2].scheme, s[2].kind, s[2].ecdsa, s[2].modelHash) = (1, 2, vm.addr(TEE_PK), keccak256(NearFixtures.DEEPSEEK));
        (s[3].scheme, s[3].kind, s[3].ecdsa) = (1, 3, vm.addr(SPONSOR_PK));
        INearConfig.Lane[] memory lanes = new INearConfig.Lane[](2);
        lanes[0] = _lane(NearFixtures.KIMI, "moonshotai", 1);
        lanes[1] = _lane(NearFixtures.DEEPSEEK, "deepseek", 2);
        TemplateT memory t = TemplateT(keccak256(systemPrompt), keccak256("rubric+schema+decoding"), 0);
        nearCfg = INearConfig(
            deployCode("BotledNearConfig.sol:BotledNearConfig", abi.encode(address(this), uint64(1 days), s, t, lanes, vm.addr(ENROLL_PK)))
        );
        verifier = INearVerifier(deployCode("BotledNearVerifier.sol:BotledNearVerifier", abi.encode(address(nearCfg))));

        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        pool = new BotledRunnerPoolNear(predicted, address(nearCfg), address(token), address(vrf), 4, 100_000, 70_000, 3);
        factory = new BotledFactoryV5Near(config, nearCfg, address(verifier), address(pool), address(po), address(0), address(0));
        assertEq(address(factory), predicted, "anchor");
        vm.deal(address(pool), 1 ether);
        token.mint(address(this), 1_000e18);
        token.approve(address(pool), 1_000e18);
        pool.fundRewards(1_000e18);

        for (uint256 i; i < 12; ++i) {
            uint256 pk = RUNNER_PK0 + i;
            address r = vm.addr(pk);
            pkOf[r] = pk;
            runners.push(r);
            _enroll(r, 1, 0);
        }
    }

    function _nearAccount(address r) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("runner-", JsonText.hexAddr(r), ".near"));
    }

    function _ticketSig(address r, uint32 epoch, uint32 covered, uint64 until) internal view returns (bytes memory) {
        (uint8 v, bytes32 rr, bytes32 ss) = vm.sign(ENROLL_PK, pool.enrollDigest(r, _nearAccount(r), epoch, covered, until, _session(r)));
        return abi.encodePacked(rr, ss, v);
    }

    function _session(address r) internal view returns (address) {
        return vm.addr(pkOf[r] + SESSION_OFFSET);
    }

    function _enroll(address r, uint32 epoch, uint32 covered) internal {
        uint64 until = uint64(block.timestamp + 30 days);
        vm.prank(keeper); // anyone relays
        pool.enroll(r, _nearAccount(r), epoch, covered, until, _session(r), _ticketSig(r, epoch, covered, until));
    }

    function _seat() internal {
        vm.prank(operator);
        cage = BotledCageV5Near(payable(factory.deployCage(0, "near-1")));
        token.mint(operator, 11_000e18);
        vm.deal(operator, 1 ether);
        vm.startPrank(operator);
        azl.approve(address(cage), 11_000e18);
        cage.seat{value: PFAND}(0, 0);
        vm.stopPrank();
        assertTrue(micro.authorized(address(cage)) && standard.authorized(address(cage)), "on both panels");
    }

    function _dispute(ArbitrationModuleV2 m) internal returns (uint256 id) {
        id = 1;
        reg.open(m, id, keccak256(POSTER_DOC));
        vm.prank(reg.worker());
        m.submitEvidence(id, keccak256(WORKER_DOC));
    }

    function _requestId(Vm.Log[] memory logs) internal view returns (uint256 id) {
        bytes32 sig = keccak256("DrawRequested(address,uint256,uint256,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(pool) && logs[i].topics[0] == sig) (id,) = abi.decode(logs[i].data, (uint256, uint256));
        }
        require(id != 0, "no draw");
    }

    function _fulfill(uint256 id, uint256 word) internal {
        uint256[] memory w = new uint256[](1);
        w[0] = word;
        vm.prank(address(vrf));
        pool.rawFulfillRandomWords(id, w);
    }

    function _open(address m, uint256 taskId, uint256 word) internal {
        (,,,,, uint64 evDeadline,,,,) = ArbitrationModuleV2(m).disputes(taskId);
        vm.warp(evDeadline + 1);
        vm.recordLogs();
        vm.prank(keeper);
        cage.openCase(m, taskId);
        _fulfill(_requestId(vm.getRecordedLogs()), word);
    }

    function _bind(address m, uint256 taskId) internal returns (uint256 gasUsed) {
        uint256 g = gasleft();
        vm.prank(keeper);
        cage.bindEvidence(m, taskId, "", POSTER_DOC, WORKER_DOC);
        gasUsed = g - gasleft();
    }

    // ================================================================ runner side (what runner-near does off-chain)

    struct Vote {
        uint8 outcome;
        uint16 bps;
        string word;
        bool reveal;
        bool ed25519;
        bool sponsored;
    }

    function _commitment(address m, uint256 taskId, uint8 r, address runner, uint8 o, uint16 b, bytes32 salt)
        internal
        view
        returns (bytes32)
    {
        bytes32 ih = cage.getCase(m, taskId).inputHash;
        return keccak256(abi.encode(address(cage), m, taskId, r, runner, ih, o, b, salt));
    }

    function _receipt(address m, uint256 taskId, address runner, uint8 lane, Vote memory v)
        internal
        view
        returns (INearVerifier.Receipt memory rc)
    {
        BotledCageV5Near.Case memory c = cage.getCase(m, taskId);
        bytes memory model = lane == 0 ? NearFixtures.KIMI : NearFixtures.DEEPSEEK;
        bytes memory userEsc = JsonText.escape(verifier.userText("", POSTER_DOC, WORKER_DOC));
        rc.request = NearFixtures.request(
            NearFixtures.head(model, systemPrompt), verifier.jurorLine(runner, c.round, c.inputHash), userEsc, NearFixtures.tail(NearFixtures.laneMaxTokens(model), schema)
        );
        rc.response = NearFixtures.response(model, NearFixtures.ruling(v.word, v.bps));
        (bytes32 rq, bytes32 rs) = (sha256(rc.request), sha256(rc.response));
        if (lane == 1) {
            rc.signerId = 2; // DeepSeek lane: its own TEE key, provider_tee text
            rc.signature = _personal(TEE_PK, verifier.signedText(2, model, rq, rs));
        } else if (v.ed25519) {
            rc.signerId = 1; // fallback slot
            rc.signature = edSigner.sign(verifier.signedText(1, model, rq, rs));
        } else {
            rc.signature = _personal(GATEWAY_PK, verifier.signedText(1, model, rq, rs));
        }
        if (v.sponsored) {
            rc.sponsorId = 3;
            (uint8 vv, bytes32 r, bytes32 ss) = vm.sign(SPONSOR_PK, nearCfg.sponsorDigest(runner, c.round, c.inputHash, rq, rs));
            rc.sponsorSig = abi.encodePacked(r, ss, vv);
        }
    }

    function _personal(uint256 pk, bytes memory text) internal pure returns (bytes memory) {
        bytes32 d = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n", JsonText.decimal(text.length), text));
        (uint8 vv, bytes32 r, bytes32 s) = vm.sign(pk, d);
        return abi.encodePacked(r, s, vv);
    }

    uint256 public lastCommitGas;
    uint256 public lastCommitGasSession;
    uint256 public lastRevealGasEcdsa;
    uint256 public lastRevealGasTee;
    uint256 public lastRevealGasEd;
    uint256 public lastRevealGasLiveness;

    /// @dev seat i (drawnRunners order) votes votes[i]; its lane is fixed by the cage: i % 2 (0 kimi, 1 deepseek).
    ///      Commits are relayed by the keeper, signed alternately by the runner's Chain Signatures key and by its
    ///      ticket session key; reveals are submitted by the keeper. Runners hold no ETH.
    function _jury(address m, uint256 taskId, Vote[] memory votes) internal returns (address[] memory list) {
        uint8 r = cage.getCase(m, taskId).round;
        list = pool.drawnRunners(address(cage), cage.drawId(m, taskId, r));
        for (uint256 i; i < list.length; ++i) {
            assertEq(list[i].balance, 0, "runner has no Base ETH");
            assertEq(pool.seat(address(cage), cage.drawId(m, taskId, r), list[i]), i + 1);
            bytes32 h = _commitment(m, taskId, r, list[i], votes[i].outcome, votes[i].bps, bytes32(i + 1));
            uint256 pk = i % 2 == 0 ? pkOf[list[i]] + SESSION_OFFSET : pkOf[list[i]];
            (uint8 v, bytes32 rr, bytes32 ss) = vm.sign(pk, verifier.commitDigest(address(cage), m, taskId, r, h));
            uint256 g = gasleft();
            vm.prank(keeper);
            cage.commitFor(m, taskId, list[i], h, abi.encodePacked(rr, ss, v));
            if (i % 2 == 0) lastCommitGasSession = g - gasleft();
            else lastCommitGas = g - gasleft();
        }
        (uint256 commitEnd,) = cage.windows(m, taskId);
        vm.warp(commitEnd + 1);
        for (uint256 i; i < list.length; ++i) {
            if (!votes[i].reveal) continue;
            INearVerifier.Receipt memory rc = _receipt(m, taskId, list[i], uint8(i % 2), votes[i]);
            uint256 g = gasleft();
            vm.prank(keeper);
            cage.reveal(m, taskId, list[i], votes[i].outcome, votes[i].bps, bytes32(i + 1), rc);
            g -= gasleft();
            if (!votes[i].sponsored) lastRevealGasLiveness = g;
            else if (i % 2 == 1) lastRevealGasTee = g;
            else if (votes[i].ed25519) lastRevealGasEd = g;
            else lastRevealGasEcdsa = g;
        }
    }

    function _votes(uint256 n, uint8 o, uint16 b, string memory w) internal pure returns (Vote[] memory v) {
        v = new Vote[](n);
        for (uint256 i; i < n; ++i) v[i] = Vote(o, b, w, true, false, true);
    }

    // ================================================================ tests

    function testFullCaseOnStandardRelayedAndReceiptBacked() public {
        _seat();
        uint256 ts = _dispute(standard);
        address m = address(standard);
        _open(m, ts, 42);
        uint256 bindGas = _bind(m, ts);
        Vote[] memory v = _votes(3, 3, 6500, "SPLIT");
        v[2].ed25519 = true; // seat 3 (kimi lane) uses the ed25519 fallback key
        address[] memory list = _jury(m, ts, v);
        vm.prank(keeper);
        cage.closeRound(m, ts);
        BotledCageV5Near.Case memory c = cage.getCase(m, ts);
        assertTrue(c.hasResult);
        vm.warp(c.deadline + 1);
        vm.prank(keeper);
        cage.finalize(m, ts);
        (,,,,,,, uint8 status, uint8 outcome,) = IAzzleArbitrationV2(m).disputes(ts);
        assertEq(status, 3, "settled on Azzle");
        assertEq(outcome, 3, "SPLIT routed");
        for (uint256 i; i < list.length; ++i) {
            (, uint32 active, uint32 noShows,,,,,) = pool.runners(list[i]);
            assertEq(active, 0);
            assertEq(noShows, 0);
            assertEq(pool.rewards(list[i]), 10e18, "equal AZL reward per counted vote");
        }
        emit log_named_uint("gas bindEvidence (2 docs, ~160 B)", bindGas);
        emit log_named_uint("gas commitFor (Chain Signatures key)", lastCommitGas);
        emit log_named_uint("gas commitFor (ticket session key)", lastCommitGasSession);
        emit log_named_uint("gas reveal kimi: ECDSA gateway + sponsor", lastRevealGasEcdsa);
        emit log_named_uint("gas reveal deepseek: ECDSA provider-TEE + sponsor", lastRevealGasTee);
        emit log_named_uint("gas reveal kimi: ed25519 gateway fallback + sponsor", lastRevealGasEd);
    }

    function testMinorityIsNotSlashedAndAppealWorks() public {
        _seat();
        uint256 ts = _dispute(standard);
        address m = address(standard);
        _open(m, ts, 7);
        _bind(m, ts);
        Vote[] memory v = _votes(3, 1, 0, "POSTER_WINS");
        v[2] = Vote(2, 10_000, "WORKER_WINS", true, false, true);
        address[] memory r1 = _jury(m, ts, v);
        vm.prank(keeper);
        cage.closeRound(m, ts);
        (, address worker) = (reg.poster(), reg.worker());
        token.mint(worker, 200e18);
        vm.startPrank(worker);
        azl.approve(address(cage), 200e18);
        vm.recordLogs();
        cage.appeal(m, ts);
        vm.stopPrank();
        _fulfill(_requestId(vm.getRecordedLogs()), 99);
        address[] memory r2 = _jury(m, ts, _votes(7, 2, 10_000, "WORKER_WINS"));
        vm.prank(keeper);
        cage.closeRound(m, ts);
        vm.warp(cage.getCase(m, ts).deadline + 1);
        vm.prank(keeper);
        cage.finalize(m, ts);
        (,,,,,,,, uint8 outcome,) = IAzzleArbitrationV2(m).disputes(ts);
        assertEq(outcome, 2, "appeal reversed");
        for (uint256 i; i < r1.length; ++i) {
            (,, uint32 noShows,,,,,) = pool.runners(r1[i]);
            assertEq(noShows, 0);
            assertTrue(pool.runnerEligible(r1[i]));
        }
        assertGt(pool.rewards(r2[0]), 0);
    }

    /// @dev Own-key (unsponsored) reveals prove liveness only: no no-show, no reward, and not counted. Here the two
    ///      sponsored kimi votes agree but cover one lane only -> no majority under the two-provider rule.
    function testLivenessRevealDoesNotCount() public {
        _seat();
        uint256 ts = _dispute(micro);
        address m = address(micro);
        _open(m, ts, 21);
        _bind(m, ts);
        Vote[] memory v = _votes(3, 1, 0, "POSTER_WINS");
        v[1].sponsored = false; // the DeepSeek seat used its own NEAR AI key
        address[] memory list = _jury(m, ts, v);
        assertEq(cage.votes(cage.caseKey(m, ts), 1, list[1]), bytes32(uint256(1)), "liveness marker");
        vm.prank(keeper);
        cage.closeRound(m, ts); // early: all 3 revealed
        BotledCageV5Near.Case memory c = cage.getCase(m, ts);
        assertFalse(c.hasResult, "2 counted kimi votes = 1 provider -> no majority");
        assertEq(c.round, 2, "automatic next round");
        emit log_named_uint("gas reveal liveness-only (own key, unsponsored)", lastRevealGasLiveness);
    }

    function testLivenessRevealAvoidsNoShowButEarnsNothing() public {
        _seat();
        uint256 ts = _dispute(standard);
        address m = address(standard);
        _open(m, ts, 21);
        _bind(m, ts);
        Vote[] memory v = _votes(3, 3, 6500, "SPLIT");
        // seats 1 (kimi) + 2 (deepseek) sponsored -> 2/3 counted, both lanes; seat 3 liveness only
        v[2].sponsored = false;
        address[] memory list = _jury(m, ts, v);
        vm.prank(keeper);
        cage.closeRound(m, ts);
        vm.warp(cage.getCase(m, ts).deadline + 1);
        vm.prank(keeper);
        cage.finalize(m, ts);
        (,, uint32 noShows,,,,,) = pool.runners(list[2]);
        assertEq(noShows, 0, "liveness reveal is not a no-show");
        assertEq(pool.rewards(list[2]), 0, "but earns no reward");
        assertEq(pool.rewards(list[0]), 15e18, "reward split among counted votes");
    }

    function testSeatLaneIsEnforced() public {
        _seat();
        uint256 ts = _dispute(micro);
        address m = address(micro);
        _open(m, ts, 5);
        _bind(m, ts);
        address[] memory list = pool.drawnRunners(address(cage), cage.drawId(m, ts, 1));
        address x = list[1]; // seat 2 -> DeepSeek lane
        bytes32 h = _commitment(m, ts, 1, x, 1, 0, bytes32(uint256(1)));
        vm.prank(x);
        cage.commit(m, ts, h);
        (uint256 commitEnd,) = cage.windows(m, ts);
        vm.warp(commitEnd + 1);
        INearVerifier.Receipt memory kimi = _receipt(m, ts, x, 0, Vote(1, 0, "POSTER_WINS", true, false, true));
        vm.expectRevert(); // Layout(): a kimi request on a DeepSeek seat
        cage.reveal(m, ts, x, 1, 0, bytes32(uint256(1)), kimi);
        INearVerifier.Receipt memory ds = _receipt(m, ts, x, 1, Vote(1, 0, "POSTER_WINS", true, false, true));
        cage.reveal(m, ts, x, 1, 0, bytes32(uint256(1)), ds);
    }

    function testRevealMustMatchSignedAnswer() public {
        _seat();
        uint256 ts = _dispute(micro);
        address m = address(micro);
        _open(m, ts, 5);
        _bind(m, ts);
        address[] memory list = pool.drawnRunners(address(cage), cage.drawId(m, ts, 1));
        address x = list[0];
        bytes32 h = _commitment(m, ts, 1, x, 2, 10_000, bytes32(uint256(1)));
        vm.prank(x);
        cage.commit(m, ts, h);
        (uint256 commitEnd,) = cage.windows(m, ts);
        vm.warp(commitEnd + 1);
        INearVerifier.Receipt memory rc = _receipt(m, ts, x, 0, Vote(1, 0, "POSTER_WINS", true, false, true));
        vm.expectRevert(BotledCageV5Near.Commitment.selector);
        cage.reveal(m, ts, x, 2, 10_000, bytes32(uint256(1)), rc);
        INearVerifier.Receipt memory other = _receipt(m, ts, list[2], 0, Vote(2, 10_000, "WORKER_WINS", true, false, true));
        vm.expectRevert(); // Layout(): receipt for another juror
        cage.reveal(m, ts, x, 2, 10_000, bytes32(uint256(1)), other);
    }

    function testRevealNeedsBoundEvidence() public {
        _seat();
        uint256 ts = _dispute(micro);
        address m = address(micro);
        _open(m, ts, 5);
        address x = pool.drawnRunners(address(cage), cage.drawId(m, ts, 1))[0];
        bytes32 h = _commitment(m, ts, 1, x, 1, 0, bytes32(uint256(1)));
        vm.prank(x);
        cage.commit(m, ts, h);
        (uint256 commitEnd,) = cage.windows(m, ts);
        vm.warp(commitEnd + 1);
        INearVerifier.Receipt memory rc;
        vm.expectRevert(BotledCageV5Near.Evidence_.selector);
        cage.reveal(m, ts, x, 1, 0, bytes32(uint256(1)), rc);
        vm.expectRevert();
        cage.bindEvidence(m, ts, "", "forged poster doc", WORKER_DOC);
        _bind(m, ts);
        vm.expectRevert(BotledCageV5Near.Phase_.selector);
        cage.bindEvidence(m, ts, "", POSTER_DOC, WORKER_DOC);
    }

    function testNoShowSuspendsUntilNearTicketCoversIt() public {
        _seat();
        uint256 ts = _dispute(micro);
        address m = address(micro);
        _open(m, ts, 11);
        _bind(m, ts);
        Vote[] memory v = _votes(3, 1, 0, "POSTER_WINS");
        v[2].reveal = false; // seat 3 silent; seats 1 (kimi) + 2 (deepseek) -> majority over both lanes
        address[] memory list = _jury(m, ts, v);
        vm.warp(block.timestamp + 3 hours);
        vm.prank(keeper);
        cage.closeRound(m, ts);
        vm.warp(cage.getCase(m, ts).deadline + 1);
        vm.prank(keeper);
        cage.finalize(m, ts);
        address silent = list[2];
        (,, uint32 noShows,,,,,) = pool.runners(silent);
        assertEq(noShows, 1);
        assertFalse(pool.runnerEligible(silent), "suspended");
        assertEq(pool.rewards(silent), 0);
        _enroll(silent, 2, 1); // NEAR charged $2 into the reward fund, MPC signed a ticket covering 1 no-show
        assertTrue(pool.runnerEligible(silent), "back after paying on NEAR");
    }

    function testEnrollmentTicketRules() public {
        address r = vm.addr(0xD00D);
        pkOf[r] = 0xD00D;
        uint64 until = uint64(block.timestamp + 1 days);
        (uint8 v, bytes32 rr, bytes32 ss) = vm.sign(0xBAD, pool.enrollDigest(r, _nearAccount(r), 1, 0, until, _session(r)));
        vm.expectRevert(BotledRunnerPoolNear.Ticket.selector);
        pool.enroll(r, _nearAccount(r), 1, 0, until, _session(r), abi.encodePacked(rr, ss, v));
        // the session key is part of the signed ticket
        bytes memory sig1 = _ticketSig(r, 1, 0, until);
        vm.expectRevert(BotledRunnerPoolNear.Ticket.selector);
        pool.enroll(r, _nearAccount(r), 1, 0, until, address(0xEE), sig1);
        pool.enroll(r, _nearAccount(r), 1, 0, until, _session(r), sig1);
        assertTrue(pool.runnerEligible(r));
        assertEq(pool.sessionKeyOf(r), _session(r));
        vm.expectRevert(BotledRunnerPoolNear.Ticket.selector);
        pool.enroll(r, _nearAccount(r), 1, 0, until, _session(r), sig1); // replay
        address r2 = vm.addr(0xD00E);
        (v, rr, ss) = vm.sign(ENROLL_PK, pool.enrollDigest(r2, _nearAccount(r), 1, 0, until, address(0)));
        vm.expectRevert(BotledRunnerPoolNear.Ticket.selector);
        pool.enroll(r2, _nearAccount(r), 1, 0, until, address(0), abi.encodePacked(rr, ss, v));
        vm.warp(until + 1);
        assertFalse(pool.runnerEligible(r));
        pool.delist(r);
        (bool listed,,,,,,,) = pool.runners(r);
        assertFalse(listed);
    }

    function testSessionKeyRotatesWithTicket() public {
        _seat();
        uint256 ts = _dispute(micro);
        address m = address(micro);
        _open(m, ts, 3);
        address x = pool.drawnRunners(address(cage), cage.drawId(m, ts, 1))[0];
        bytes32 h = _commitment(m, ts, 1, x, 1, 0, bytes32(uint256(1)));
        bytes32 d = verifier.commitDigest(address(cage), m, ts, 1, h);
        // new ticket with a new session key: the old one stops working
        uint256 oldPk = pkOf[x] + SESSION_OFFSET;
        pkOf[x] += 7; // _session() now derives a different key
        uint64 until = uint64(block.timestamp + 7 days);
        pkOf[x] -= 7;
        address newSession = vm.addr(0xC0FFEE);
        (uint8 tv, bytes32 tr, bytes32 tss) = vm.sign(ENROLL_PK, pool.enrollDigest(x, _nearAccount(x), 2, 0, until, newSession));
        pool.enroll(x, _nearAccount(x), 2, 0, until, newSession, abi.encodePacked(tr, tss, tv));
        (uint8 v, bytes32 rr, bytes32 ss) = vm.sign(oldPk, d);
        vm.expectRevert(BotledCageV5Near.Auth.selector);
        cage.commitFor(m, ts, x, h, abi.encodePacked(rr, ss, v));
        (v, rr, ss) = vm.sign(0xBAD, d);
        vm.expectRevert(BotledCageV5Near.Auth.selector);
        cage.commitFor(m, ts, x, h, abi.encodePacked(rr, ss, v));
        (v, rr, ss) = vm.sign(0xC0FFEE, d);
        cage.commitFor(m, ts, x, h, abi.encodePacked(rr, ss, v));
    }

    function testOnlyAnchoredCagesUsePool() public {
        vm.expectRevert(BotledRunnerPoolNear.NotCage.selector);
        pool.requestDraw(1, address(1), address(2), 3, uint64(block.timestamp + 1 hours));
        uint8[] memory r = new uint8[](0);
        vm.expectRevert(BotledRunnerPoolNear.NotCage.selector);
        pool.settleDraw(1, r, true, 0);
    }

    /// @dev cross-language vector for near/botled-logic (ticket::enroll_digest)
    function testEnrollDigestVector() public {
        vm.chainId(8453);
        bytes32 nearAccount = keccak256("runner.botled.near");
        address r = 0x1111111111111111111111111111111111111111;
        address sk = 0x3333333333333333333333333333333333333333;
        bytes32 got = pool.enrollDigest(r, nearAccount, 7, 2, 1_800_000_000, sk);
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("BotledRunnerPoolNear"),
                keccak256("1"),
                uint256(8453),
                address(pool)
            )
        );
        bytes32 structHash =
            keccak256(abi.encode(pool.ENROLL_TYPEHASH(), r, nearAccount, uint32(7), uint32(2), uint64(1_800_000_000), sk));
        assertEq(got, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        emit log_named_address("vector pool", address(pool));
        emit log_named_bytes32("vector digest", got);
    }

    /// @dev cross-language vectors for runner-near/request.ts (both lanes, VECTOR_CASE)
    function testRequestVector() public {
        address r = 0x1111111111111111111111111111111111111111;
        bytes32 ih = bytes32(uint256(0x22) * (type(uint256).max / 0xff));
        bytes memory userEsc = JsonText.escape(verifier.userText("Build /refund.", POSTER_DOC, WORKER_DOC));
        bytes memory req = NearFixtures.request(
            NearFixtures.head(NearFixtures.KIMI, systemPrompt), verifier.jurorLine(r, 1, ih), userEsc,
            NearFixtures.tail(NearFixtures.KIMI_MAX_TOKENS, schema)
        );
        emit log_named_bytes32("vector kimi request sha256", sha256(req));
        emit log_named_uint("vector kimi request length", req.length);
        req = NearFixtures.request(
            NearFixtures.head(NearFixtures.DEEPSEEK, systemPrompt), verifier.jurorLine(r, 1, ih), userEsc,
            NearFixtures.tail(NearFixtures.DEEPSEEK_MAX_TOKENS, schema)
        );
        emit log_named_bytes32("vector deepseek request sha256", sha256(req));
        emit log_named_uint("vector deepseek request length", req.length);
    }

    /// @dev sponsor digest vector for the relay (runner-near/relay.ts) and botled-logic
    function testSponsorDigestVector() public {
        vm.chainId(8453);
        bytes32 d = nearCfg.sponsorDigest(
            0x1111111111111111111111111111111111111111, 1, bytes32(uint256(0x22) * (type(uint256).max / 0xff)),
            bytes32(uint256(0xaa)), bytes32(uint256(0xbb))
        );
        emit log_named_address("vector nearConfig", address(nearCfg));
        emit log_named_bytes32("vector sponsor digest", d);
    }

    // ================================================================ REAL NEAR AI receipts through the full cage

    address constant VRUNNER = 0x1111111111111111111111111111111111111111;
    bytes32 constant VINPUT = 0x2222222222222222222222222222222222222222222222222222222222222222;
    bytes constant VSCOPE = "Build /refund.";
    bytes constant VPOSTER = "Poster: delivery misses the /refund endpoint that the scope requires.";
    bytes constant VWORKER = "Worker: commit 9f2c implements /refund; see tests/refund.spec.ts (41/41 green).\nDeadline met.";

    /// @dev The paid receipts in test/near-vectors/real were produced for runner VRUNNER, round 1, inputHash VINPUT and
    ///      the V* documents. This drives them through openCase -> bindEvidence -> commit -> reveal on the real cage;
    ///      only inputHash and scopeHash are patched in storage (they derive from chain state we cannot reproduce).
    ///      Measures the FULL `reveal` tx gas (cage + verifier + parser + signature + sponsor co-sig).
    function testRealReceiptsFullRevealGas() public {
        // pinned real NEAR AI keys (see runner-near/attestation-pins.json), activated through the timelock
        INearConfig.Signer[] memory s = new INearConfig.Signer[](4);
        (s[0].scheme, s[0].kind, s[0].ecdsa) = (1, 1, 0xb98A789Cdc4817275F5155593ba73EF2a957e779);
        (s[1].scheme, s[1].kind) = (2, 1);
        s[1].edKey = _realGwEdKey();
        (s[2].scheme, s[2].kind, s[2].ecdsa, s[2].modelHash) =
            (1, 2, 0xfe0071895500A9755C18044948AB4f4e1A7f337e, keccak256(NearFixtures.DEEPSEEK));
        (s[3].scheme, s[3].kind, s[3].modelHash) = (2, 2, keccak256(NearFixtures.DEEPSEEK));
        s[3].edKey = [
            uint256(17434810981884461409275962346463205779709739437501424370853330652094074868461),
            uint256(22810675813067226280537522601436914280248282412383173995532820579254066382470), 0, 0,
            uint256(0x236f5a6b91dd47dc3b7b36e43d4eb531a042ffb8f8fbf3a1555b78cef4fdda4c)
        ];
        uint32[4] memory id;
        for (uint256 i; i < 4; ++i) id[i] = IRealCfg(address(nearCfg)).proposeSigner(s[i]);
        vm.warp(block.timestamp + 1 days + 1);
        _enroll(VRUNNER, 1, 0);
        _seat();

        string[4] memory name = ["kimi ecdsa", "kimi ed25519", "deepseek ecdsa", "deepseek ed25519"];
        for (uint256 j; j < 4; ++j) {
            uint256 snap = vm.snapshotState();
            uint8 lane = j < 2 ? 0 : 1;
            (uint256 gasCounted) = _realReveal(lane, id[j], j % 2 == 1, true);
            vm.revertToState(snap);
            snap = vm.snapshotState();
            (uint256 gasLiveness) = _realReveal(lane, id[j], j % 2 == 1, false);
            vm.revertToState(snap);
            emit log_named_uint(string.concat("gas FULL reveal REAL ", name[j], " sponsored (counted)"), gasCounted);
            emit log_named_uint(string.concat("gas FULL reveal REAL ", name[j], " own key (liveness)"), gasLiveness);
            assertLt(gasCounted, 2_000_000, "fits a Base tx comfortably");
        }
    }

    function _realGwEdKey() internal pure returns (uint256[5] memory k) {
        k = [
            uint256(42676130079551593973673125876230518046791080229428114621746360344985801889187),
            uint256(35291603471346667703562426432940291986318014996113700382611454260910592915546), 0, 0,
            uint256(0x40599fb284f43953bb356b09080fd803c960fc10285ad90eca462ca711ad4acb)
        ];
    }

    function _realReveal(uint8 lane, uint32 signerId, bool ed25519, bool sponsored) internal returns (uint256 gasUsed) {
        address m = address(micro);
        uint256 ts = 1;
        reg.open(micro, ts, keccak256(VPOSTER));
        vm.prank(reg.worker());
        micro.submitEvidence(ts, keccak256(VWORKER));
        (,,,,, uint64 evDeadline,,,,) = micro.disputes(ts);
        vm.warp(evDeadline + 1);
        // find a VRF word that seats VRUNNER on a seat of `lane`
        bytes32 k = cage.caseKey(m, ts);
        vm.recordLogs();
        vm.prank(keeper);
        cage.openCase(m, ts);
        uint256 req = _requestId(vm.getRecordedLogs());
        uint256 did = cage.drawId(m, ts, 1);
        for (uint256 w = 1;; ++w) {
            uint256 snap = vm.snapshotState();
            _fulfill(req, w);
            uint8 seat_ = pool.seat(address(cage), did, VRUNNER);
            if (seat_ != 0 && (seat_ - 1) % 2 == lane) break;
            vm.revertToState(snap);
            require(w < 400, "no seat");
        }
        bytes32 caseSlot = keccak256(abi.encode(k, uint256(2)));
        vm.store(address(cage), bytes32(uint256(caseSlot) + 1), VINPUT); // Case.inputHash
        bytes32 evSlot = keccak256(abi.encode(k, uint256(7)));
        vm.store(address(cage), bytes32(uint256(evSlot) + 2), keccak256(VSCOPE)); // Evidence.scopeHash
        vm.prank(keeper);
        cage.bindEvidence(m, ts, VSCOPE, VPOSTER, VWORKER);
        assertEq(cage.getCase(m, ts).inputHash, VINPUT);

        // the real receipts' signed answer: WORKER_WINS, 10000
        bytes32 salt = keccak256("real");
        bytes32 h = keccak256(abi.encode(address(cage), m, ts, uint8(1), VRUNNER, VINPUT, uint8(2), uint16(10_000), salt));
        vm.prank(VRUNNER);
        cage.commit(m, ts, h);
        (uint256 commitEnd,) = cage.windows(m, ts);
        vm.warp(commitEnd + 1);

        string memory base = string.concat("test/near-vectors/real/", lane == 0 ? "kimi" : "deepseek");
        string memory meta = vm.readFile(string.concat(base, ".receipt.json"));
        INearVerifier.Receipt memory rc;
        rc.request = vm.readFileBinary(string.concat(base, ".request.json"));
        rc.response = vm.readFileBinary(string.concat(base, ".response.json"));
        rc.signerId = signerId;
        rc.signature = vm.parseJsonBytes(meta, ed25519 ? ".signatures.ed25519.signature" : ".signatures.ecdsa.signature");
        if (sponsored) {
            rc.sponsorId = 3;
            (uint8 vv, bytes32 r, bytes32 ss) =
                vm.sign(SPONSOR_PK, nearCfg.sponsorDigest(VRUNNER, 1, VINPUT, sha256(rc.request), sha256(rc.response)));
            rc.sponsorSig = abi.encodePacked(r, ss, vv);
        }
        uint256 g = gasleft();
        vm.prank(keeper);
        cage.reveal(m, ts, VRUNNER, 2, 10_000, salt, rc);
        gasUsed = g - gasleft();
        assertEq(cage.votes(k, 1, VRUNNER), sponsored ? keccak256(abi.encode(uint8(2), uint16(10_000))) : bytes32(uint256(1)));
    }
}

interface IRealCfg {
    function proposeSigner(INearConfig.Signer calldata s) external returns (uint32);
}
