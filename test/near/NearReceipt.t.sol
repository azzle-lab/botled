// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ed25519} from "../../src/botled/v5near/lib/Ed25519.sol";
import {JsonText} from "../../src/botled/v5near/lib/JsonText.sol";
import {RulingParser} from "../../src/botled/v5near/lib/RulingParser.sol";
import {BotledNearConfig} from "../../src/botled/v5near/BotledNearConfig.sol";
import {BotledNearVerifier} from "../../src/botled/v5near/BotledNearVerifier.sol";
import {INearVerifier} from "../../src/botled/v5near/interfaces/IBotledNear.sol";
import {SCL_EIP6565_UTILS} from "@solidity/lib/libSCL_eddsaUtils.sol";
import {NearFixtures} from "./NearFixtures.sol";

contract ParserHarness {
    function parse(bytes calldata r) external pure returns (bool, uint8, uint16) { return RulingParser.parse(r); }
}

contract Ed25519Harness {
    function verify(bytes calldata m, bytes calldata sig, uint256[5] calldata k) external view returns (bool) {
        return Ed25519.verify(m, sig, k);
    }
    function isExtKey(uint256[5] calldata k) external view returns (bool) { return Ed25519.isExtKey(k); }
}

/// @notice NEAR AI receipt primitives: ed25519 (real gateway vector), ECDSA, request layout, response parsing,
///         timelocked key registry. Compiled with the legacy pipeline (see foundry.toml).
contract NearReceiptTest is Test {
    // ---- REAL NEAR AI gateway material, fetched 2026-11-20 from
    //      GET https://cloud-api.near.ai/v1/attestation/report?signing_algo=ed25519  (no API key, no payment)
    bytes32 constant GATEWAY_ED25519 = 0x40599fb284f43953bb356b09080fd803c960fc10285ad90eca462ca711ad4acb;
    // ohttp_attestation: the gateway key's ed25519 signature over the raw OHTTP key_config bytes
    bytes constant OHTTP_KEY_CONFIG = hex"010020e4e354364111f2295e2d2ed97ce1103c9fdcb261459ec626d9bd8a6e15f0d11600080001000100010003";
    bytes constant OHTTP_SIG =
        hex"823086655feb1660e7975d8dfdbfd728af36cc7776f69f7b5f713753306d5a8a96b1bc49298800ef36c06ccccfeed13e1fbc4b48233496af3a3a514b6d61680b";
    // tools/ed25519_extkey.py 40599fb2...
    uint256 constant GW_WX = 42676130079551593973673125876230518046791080229428114621746360344985801889187;
    uint256 constant GW_WY = 35291603471346667703562426432940291986318014996113700382611454260910592915546;
    // gateway ECDSA identity from ...?signing_algo=ecdsa (EIP-191 signer)
    address constant GATEWAY_ECDSA = 0xb98A789Cdc4817275F5155593ba73EF2a957e779;

    // ---- python `cryptography` RFC 8032 vector (seed = 0x11 * 32)
    bytes32 constant PY_PUB = 0xd04ab232742bb4ab3a1368bd4615e4e6d0224ab71a016baf8520a332c9778737;
    bytes constant PY_TEXT =
        "78b0e11c6754fc9671c2034f4a068d3a0e53c1c22a5a33900dd46bc8cd9136f3:1bba8f7c49a4655a1f7959d670ca160870b6ec960767a215c4ce03c8c9724f07";
    bytes constant PY_SIG =
        hex"bde1a52e1e4e7a9d9cafaaabcbfb392fdb1190eec35678d4f079db85cd34286f66c7742e4444d2dcec7d7ab24a77e016ddee8a69a31af46e227b9ff3e35dbc07";

    ParserHarness parser;
    Ed25519Harness ed;
    bytes systemPrompt;
    bytes schema;

    function setUp() public {
        parser = new ParserHarness();
        ed = new Ed25519Harness();
        systemPrompt = bytes(vm.readFile("test/near-vectors/system_prompt.txt"));
        schema = bytes(vm.readFile("test/near-vectors/schema.compact.json"));
    }

    function _gwKey() internal pure returns (uint256[5] memory k) {
        k = [GW_WX, GW_WY, 0, 0, uint256(GATEWAY_ED25519)];
    }

    // ================================================================ ed25519

    function testRealNearAiGatewaySignatureVerifies() public {
        uint256[5] memory k = _gwKey();
        assertTrue(ed.isExtKey(k), "extended key maps to the real gateway key");
        uint256 g = gasleft();
        bool ok = ed.verify(OHTTP_KEY_CONFIG, OHTTP_SIG, k);
        uint256 used = g - gasleft();
        assertTrue(ok, "real NEAR AI gateway ed25519 signature");
        emit log_named_uint("gas ed25519 verify (41-byte msg, real gateway sig)", used);
        bytes memory bad = OHTTP_KEY_CONFIG;
        bad[5] ^= 0x01;
        assertFalse(ed.verify(bad, OHTTP_SIG, k), "tampered message");
        bytes memory badSig = OHTTP_SIG;
        badSig[40] ^= 0x01;
        assertFalse(ed.verify(OHTTP_KEY_CONFIG, badSig, k), "tampered S");
    }

    function testPythonRfc8032VectorAndReceiptTextGas() public {
        uint256[5] memory k = _pyKey();
        assertTrue(ed.isExtKey(k));
        uint256 g = gasleft();
        bool ok = ed.verify(PY_TEXT, PY_SIG, k);
        uint256 used = g - gasleft();
        assertTrue(ok, "python-signed gateway-format receipt text (129 bytes)");
        emit log_named_uint("gas ed25519 verify (129-byte gateway receipt text)", used);
        // SCL's own signer is RFC 8032 deterministic: same seed + text => byte-identical signature
        (uint256[5] memory sk, uint256[2] memory signer) = SCL_EIP6565_UTILS.SetKey(uint256(bytes32(hex"1111111111111111111111111111111111111111111111111111111111111111")));
        assertEq(bytes32(sk[4]), PY_PUB, "SCL keygen == RFC 8032 public key");
        (uint256 r, uint256 s) = SCL_EIP6565_UTILS.Sign(sk[4], signer, string(PY_TEXT));
        assertEq(abi.encodePacked(r, s), PY_SIG, "SCL signature == python signature");
    }

    function _pyKey() internal view returns (uint256[5] memory k) {
        (uint256[5] memory sk,) = SCL_EIP6565_UTILS.SetKey(uint256(bytes32(hex"1111111111111111111111111111111111111111111111111111111111111111")));
        k = [sk[0], sk[1], 0, 0, sk[4]];
    }

    function testExtKeyRejectsWrongPoint() public view {
        uint256[5] memory k = _gwKey();
        k[1] = k[1] + 1;
        assertFalse(ed.isExtKey(k), "off-curve");
        k = _gwKey();
        k[4] = uint256(PY_PUB);
        assertFalse(ed.isExtKey(k), "point does not match raw key");
    }

    // ================================================================ JSON escaping (= runner client)

    function testEscapeMatchesJsonStringify() public pure {
        // expected values = JSON.stringify(s).slice(1, -1) in node
        assertEq(JsonText.escape('a"b\\c'), 'a\\"b\\\\c');
        assertEq(JsonText.escape("l1\nl2\tx\r"), "l1\\nl2\\tx\\r");
        assertEq(JsonText.escape(hex"01081f7f"), hex"5c75303030315c625c7530303166" hex"7f");
        assertEq(JsonText.escape(unicode"Grüße / ok"), unicode"Grüße / ok");
    }

    // ================================================================ response parsing

    function _p(bytes memory r) internal view returns (bool ok, uint8 o, uint16 b) { return parser.parse(r); }

    function testParseCompactWithReasoningDecoy() public view {
        (bool ok, uint8 o, uint16 b) = _p(NearFixtures.response(NearFixtures.KIMI, NearFixtures.ruling("SPLIT", 6500)));
        assertTrue(ok);
        assertEq(o, 3);
        assertEq(b, 6500);
    }

    function testParsePrettyAndReordered() public view {
        bytes memory content = '{\n  "workerBps": 0,\n  "outcome": "POSTER_WINS",\n  "reason": "late"\n}';
        bytes memory r = abi.encodePacked(
            '{\n "id": "x",\n "choices": [ {\n  "message": {\n   "role": "assistant",\n   "content": "', JsonText.escape(content),
            '"\n  }\n } ]\n}'
        );
        (bool ok, uint8 o, uint16 b) = _p(r);
        assertTrue(ok);
        assertEq(o, 1);
        assertEq(b, 0);
    }

    function testParseRejects() public view {
        bool ok;
        // two structural "content" keys (e.g. n=2) -> ambiguous
        bytes memory c = JsonText.escape(NearFixtures.ruling("WORKER_WINS", 10_000));
        (ok,,) = _p(abi.encodePacked('{"choices":[{"message":{"content":"', c, '"}},{"message":{"content":"', c, '"}}]}'));
        assertFalse(ok, "ambiguous");
        // null content (refusal)
        (ok,,) = _p('{"choices":[{"message":{"content":null}}]}');
        assertFalse(ok, "null");
        // unknown outcome / leading zero / out of range / missing workerBps
        (ok,,) = _p(abi.encodePacked('{"content":"', JsonText.escape('{"outcome":"MAYBE","workerBps":0}'), '"}'));
        assertFalse(ok, "enum");
        (ok,,) = _p(abi.encodePacked('{"content":"', JsonText.escape('{"outcome":"SPLIT","workerBps":05000}'), '"}'));
        assertFalse(ok, "leading zero");
        (ok,,) = _p(abi.encodePacked('{"content":"', JsonText.escape('{"outcome":"SPLIT","workerBps":10001}'), '"}'));
        assertFalse(ok, "range");
        (ok,,) = _p(abi.encodePacked('{"content":"', JsonText.escape('{"outcome":"SPLIT","reason":"x","workerBps":5000}'), '"}'));
        assertFalse(ok, "reason before workerBps");
        // answer only inside reasoning_content -> not found
        (ok,,) = _p(abi.encodePacked('{"reasoning_content":"', c, '"}'));
        assertFalse(ok, "decoy only");
    }

    // ================================================================ registry + full receipt check

    BotledNearConfig cfg;
    BotledNearVerifier ver;
    uint256 gwPk = 0xA11CE;
    uint256 constant TEE_PK = 0x7EE;     // stands in for the DeepSeek-V4.1-Flash-1017 TEE key
    uint256 constant SPONSOR_PK = 0x5905; // Botled sponsor relay key
    uint32 constant GW_ECDSA = 0;
    uint32 constant GW_ED = 1;
    uint32 constant DS_TEE = 2;
    uint32 constant SPONSOR = 3;

    function _deploy() internal {
        BotledNearConfig.Signer[] memory s = new BotledNearConfig.Signer[](4);
        (s[0].scheme, s[0].kind, s[0].ecdsa) = (1, 1, vm.addr(gwPk));
        (s[1].scheme, s[1].kind, s[1].edKey) = (2, 1, _pyKey());
        (s[2].scheme, s[2].kind, s[2].ecdsa, s[2].modelHash) = (1, 2, vm.addr(TEE_PK), keccak256(NearFixtures.DEEPSEEK));
        (s[3].scheme, s[3].kind, s[3].ecdsa) = (1, 3, vm.addr(SPONSOR_PK));
        BotledNearConfig.Lane[] memory l = new BotledNearConfig.Lane[](2);
        l[0] = _lane(NearFixtures.KIMI, "moonshotai", 1);
        l[1] = _lane(NearFixtures.DEEPSEEK, "deepseek", 2);
        BotledNearConfig.Template memory t;
        t.systemPromptHash = keccak256(systemPrompt);
        t.rubricHash = keccak256("rubric");
        cfg = new BotledNearConfig(address(this), 1 days, s, t, l, address(0xE11));
        ver = new BotledNearVerifier(address(cfg));
    }

    function _lane(bytes memory model, bytes32 provider, uint8 kind) internal view returns (BotledNearConfig.Lane memory l) {
        bytes memory h = NearFixtures.head(model, systemPrompt);
        bytes memory t = NearFixtures.tail(NearFixtures.laneMaxTokens(model), schema);
        l = BotledNearConfig.Lane(model, provider, keccak256(h), keccak256(t), uint32(h.length), uint32(t.length), kind);
    }

    bytes constant POSTER_DOC = "Poster: the delivered API misses the /refund endpoint required by the scope.";
    bytes constant WORKER_DOC = "Worker: delivered commit 9f2c; \"refund\" is in v2 per chat.\nTests: 41/41 pass.";
    bytes constant SCOPE = "Build a REST API with /pay and /refund. Deadline 2026-11-30.";

    function _ctx(address runner, bytes32 inputHash, bytes memory model) internal view returns (INearVerifier.Ctx memory c) {
        (bytes32 uh, uint32 ul) = ver.userBinding(SCOPE, POSTER_DOC, WORKER_DOC);
        uint8 laneIdx = keccak256(model) == keccak256(NearFixtures.KIMI) ? 0 : 1;
        c = INearVerifier.Ctx(0, laneIdx, runner, 1, inputHash, uh, ul);
    }

    function _req(address runner, bytes32 inputHash, bytes memory model) internal view returns (bytes memory) {
        bytes memory userEsc = JsonText.escape(ver.userText(SCOPE, POSTER_DOC, WORKER_DOC));
        return NearFixtures.request(
            NearFixtures.head(model, systemPrompt), ver.jurorLine(runner, 1, inputHash), userEsc,
            NearFixtures.tail(NearFixtures.laneMaxTokens(model), schema)
        );
    }

    function _fixture(address runner, bytes32 inputHash, bytes memory model, string memory outcome, uint256 bps)
        internal
        view
        returns (INearVerifier.Ctx memory c, bytes memory req, bytes memory resp)
    {
        c = _ctx(runner, inputHash, model);
        req = _req(runner, inputHash, model);
        resp = NearFixtures.response(model, NearFixtures.ruling(outcome, bps));
    }

    function _personal(uint256 pk, bytes memory text) internal pure returns (bytes memory) {
        bytes32 d = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n", JsonText.decimal(text.length), text));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, d);
        return abi.encodePacked(r, s, v);
    }

    function _ecdsaSign(bytes memory text) internal view returns (bytes memory) {
        return _personal(gwPk, text);
    }

    function _rc(bytes memory req, bytes memory resp, uint32 id, bytes memory sig) internal pure returns (INearVerifier.Receipt memory r) {
        r.request = req;
        r.response = resp;
        r.signerId = id;
        r.signature = sig;
    }

    function _sponsorSig(uint256 pk, INearVerifier.Ctx memory c, bytes memory req, bytes memory resp) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, cfg.sponsorDigest(c.runner, c.round, c.inputHash, sha256(req), sha256(resp)));
        return abi.encodePacked(r, s, v);
    }

    function _chk(INearVerifier.Ctx memory c, INearVerifier.Receipt memory r) internal view returns (uint8 o, uint16 b, bool sp) {
        (o, b,,, sp) = ver.check(c, r);
    }

    function testFullReceiptEcdsaAndEd25519() public {
        _deploy();
        address runner = address(0xBEEF);
        (INearVerifier.Ctx memory c, bytes memory req, bytes memory resp) = _fixture(runner, keccak256("case"), NearFixtures.KIMI, "SPLIT", 7000);
        bytes memory text = ver.signedText(1, NearFixtures.KIMI, sha256(req), sha256(resp));
        emit log_named_uint("request bytes", req.length);
        emit log_named_uint("response bytes", resp.length);

        uint256 g = gasleft();
        (uint8 o, uint16 b, bool sp) = _chk(c, _rc(req, resp, GW_ECDSA, _ecdsaSign(text)));
        emit log_named_uint("gas full receipt check, ECDSA gateway (unsponsored)", g - gasleft());
        assertEq(o, 3);
        assertEq(b, 7000);
        assertFalse(sp);

        (, uint256[2] memory signer) = SCL_EIP6565_UTILS.SetKey(uint256(bytes32(hex"1111111111111111111111111111111111111111111111111111111111111111")));
        (uint256 r, uint256 s) = SCL_EIP6565_UTILS.Sign(uint256(PY_PUB), signer, string(text));
        g = gasleft();
        (o, b,) = _chk(c, _rc(req, resp, GW_ED, abi.encodePacked(r, s)));
        emit log_named_uint("gas full receipt check, ed25519 gateway fallback (unsponsored)", g - gasleft());
        assertEq(o, 3);

        INearVerifier.Receipt memory rc = _rc(req, resp, GW_ECDSA, _ecdsaSign(text));
        rc.sponsorId = SPONSOR;
        rc.sponsorSig = _sponsorSig(SPONSOR_PK, c, req, resp);
        g = gasleft();
        (,, sp) = _chk(c, rc);
        emit log_named_uint("gas full receipt check, ECDSA gateway + sponsor co-signature", g - gasleft());
        assertTrue(sp);
    }

    function testSponsorCoSignature() public {
        _deploy();
        (INearVerifier.Ctx memory c, bytes memory req, bytes memory resp) = _fixture(address(0xBEEF), keccak256("case"), NearFixtures.KIMI, "SPLIT", 7000);
        INearVerifier.Receipt memory rc = _rc(req, resp, GW_ECDSA, _ecdsaSign(ver.signedText(1, NearFixtures.KIMI, sha256(req), sha256(resp))));
        rc.sponsorId = SPONSOR;
        // not the sponsor key
        rc.sponsorSig = _sponsorSig(0xBAD, c, req, resp);
        vm.expectRevert(BotledNearVerifier.Sponsor.selector);
        ver.check(c, rc);
        // a NEAR AI key is not a sponsor key
        rc.sponsorId = GW_ECDSA;
        rc.sponsorSig = _sponsorSig(gwPk, c, req, resp);
        vm.expectRevert(BotledNearVerifier.Sponsor.selector);
        ver.check(c, rc);
        // co-signed for another juror seat
        INearVerifier.Ctx memory other = _copy(c);
        other.round = 2;
        rc.sponsorId = SPONSOR;
        rc.sponsorSig = _sponsorSig(SPONSOR_PK, other, req, resp);
        vm.expectRevert(BotledNearVerifier.Sponsor.selector);
        ver.check(c, rc);
    }

    function _spSig(address runner, bytes32 ih, bytes32 rq, bytes32 rs) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SPONSOR_PK, cfg.sponsorDigest(runner, 1, ih, rq, rs));
        return abi.encodePacked(r, s, v);
    }

    function testSponsorEquivocationRetiresKeyAtOnce() public {
        _deploy();
        address runner = address(0xBEEF);
        bytes32 ih = keccak256("case");
        bytes32[2] memory rq = [sha256("req"), sha256("req")];
        bytes32[2] memory rs = [sha256("resp A"), sha256("resp B")]; // two samples for one seat
        bytes memory sa = _spSig(runner, ih, rq[0], rs[0]);
        bytes memory sb = _spSig(runner, ih, rq[1], rs[1]);
        vm.expectRevert(BotledNearConfig.Config.selector); // same run twice is not equivocation
        cfg.reportEquivocation(SPONSOR, runner, 1, ih, [rq[0], rq[0]], [rs[0], rs[0]], sa, sa);
        vm.expectRevert(BotledNearConfig.Config.selector); // only sponsor keys
        cfg.reportEquivocation(GW_ECDSA, runner, 1, ih, rq, rs, sa, sb);
        assertTrue(cfg.isSignerActive(SPONSOR));
        vm.prank(address(0x5EE)); // anyone
        cfg.reportEquivocation(SPONSOR, runner, 1, ih, rq, rs, sa, sb);
        assertFalse(cfg.isSignerActive(SPONSOR), "retired immediately");
    }

    function _equivocate(uint256 pk, uint32 id) internal {
        bytes32 ih = keccak256("other case");
        bytes32[2] memory rq = [sha256("q"), sha256("q")];
        bytes32[2] memory rs = [sha256("a"), sha256("b")];
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(pk, cfg.sponsorDigest(address(7), 1, ih, rq[0], rs[0]));
        bytes memory a = abi.encodePacked(r1, s1, v1);
        (v1, r1, s1) = vm.sign(pk, cfg.sponsorDigest(address(7), 1, ih, rq[1], rs[1]));
        cfg.reportEquivocation(id, address(7), 1, ih, rq, rs, a, abi.encodePacked(r1, s1, v1));
    }

    /// Two independent relays: retiring one sponsor key (equivocation) does not halt juries.
    function testSecondSponsorKeepsJuriesRunningWhenOneIsRetired() public {
        _deploy();
        uint256 pkB = 0x5906;
        BotledNearConfig.Signer memory sb;
        (sb.scheme, sb.kind, sb.ecdsa) = (1, 3, vm.addr(pkB));
        uint32 idB = cfg.proposeSigner(sb);
        vm.warp(block.timestamp + 1 days + 1);
        assertTrue(cfg.isSignerActive(idB));

        address runner = address(0xBEEF);
        (INearVerifier.Ctx memory c, bytes memory req, bytes memory resp) = _fixture(runner, keccak256("case"), NearFixtures.KIMI, "SPLIT", 7000);
        INearVerifier.Receipt memory rc = _rc(req, resp, GW_ECDSA, _ecdsaSign(ver.signedText(1, NearFixtures.KIMI, sha256(req), sha256(resp))));

        _equivocate(SPONSOR_PK, SPONSOR); // relay A equivocates on some other seat -> retired at once, by anyone
        assertFalse(cfg.isSignerActive(SPONSOR));

        // A's co-signature no longer counts
        rc.sponsorId = SPONSOR;
        rc.sponsorSig = _sponsorSig(SPONSOR_PK, c, req, resp);
        vm.expectRevert(BotledNearVerifier.Sponsor.selector);
        ver.check(c, rc);
        // B's does
        rc.sponsorId = idB;
        rc.sponsorSig = _sponsorSig(pkB, c, req, resp);
        (,, bool counted) = _chk(c, rc);
        assertTrue(counted, "relay B keeps votes counted");
        // and the own-key path still proves liveness
        rc.sponsorId = 0;
        rc.sponsorSig = "";
        (,, counted) = _chk(c, rc);
        assertFalse(counted);
    }

    function testReceiptBindsJurorCaseLaneAndSigner() public {
        _deploy();
        address runner = address(0xBEEF);
        (INearVerifier.Ctx memory c, bytes memory req, bytes memory resp) = _fixture(runner, keccak256("case"), NearFixtures.KIMI, "POSTER_WINS", 0);
        bytes memory sig = _ecdsaSign(ver.signedText(1, NearFixtures.KIMI, sha256(req), sha256(resp)));

        INearVerifier.Ctx memory other = _copy(c);
        other.runner = address(0xCAFE); // copied receipt
        vm.expectRevert(BotledNearVerifier.Layout.selector);
        ver.check(other, _rc(req, resp, GW_ECDSA, sig));
        other = _copy(c);
        other.round = 2; // replay into the next round
        vm.expectRevert(BotledNearVerifier.Layout.selector);
        ver.check(other, _rc(req, resp, GW_ECDSA, sig));
        other = _copy(c);
        other.inputHash = keccak256("other case");
        vm.expectRevert(BotledNearVerifier.Layout.selector);
        ver.check(other, _rc(req, resp, GW_ECDSA, sig));
        other = _copy(c);
        other.lane = 1; // seat is DeepSeek, request is Kimi
        vm.expectRevert(BotledNearVerifier.Layout.selector);
        ver.check(other, _rc(req, resp, GW_ECDSA, sig));
        // forged response (different answer) under the same signature
        bytes memory forged = NearFixtures.response(NearFixtures.KIMI, NearFixtures.ruling("WORKER_WINS", 10_000));
        vm.expectRevert(BotledNearVerifier.Signature.selector);
        ver.check(c, _rc(req, forged, GW_ECDSA, sig));
        // signature by an unknown key
        gwPk = 0xBAD;
        bytes memory sig2 = _ecdsaSign(ver.signedText(1, NearFixtures.KIMI, sha256(req), sha256(resp)));
        vm.expectRevert(BotledNearVerifier.Signature.selector);
        ver.check(c, _rc(req, resp, GW_ECDSA, sig2));
        // unknown signer id
        vm.expectRevert(BotledNearVerifier.Signer_.selector);
        ver.check(c, _rc(req, resp, 7, sig));
    }

    function _teeSig(uint256 pk, bytes memory model, bytes memory req, bytes memory resp) internal view returns (bytes memory) {
        return _personal(pk, ver.signedText(2, model, sha256(req), sha256(resp)));
    }

    function _proposeTee(uint256 pk, bytes memory model) internal returns (uint32) {
        BotledNearConfig.Signer memory s;
        s.scheme = 1;
        s.kind = 2;
        s.ecdsa = vm.addr(pk);
        s.modelHash = keccak256(model);
        return cfg.proposeSigner(s);
    }

    function _copy(INearVerifier.Ctx memory c) internal pure returns (INearVerifier.Ctx memory) {
        return INearVerifier.Ctx(c.templateId, c.lane, c.runner, c.round, c.inputHash, c.userHash, c.userLen);
    }

    function _dsFixture() internal view returns (INearVerifier.Ctx memory c, bytes memory req, bytes memory resp) {
        return _fixture(address(0xBEEF), keccak256("case"), NearFixtures.DEEPSEEK, "MUTUAL", 5000);
    }

    function testPerLaneKeys() public {
        _deploy();
        (INearVerifier.Ctx memory c, bytes memory req, bytes memory resp) = _dsFixture();
        uint256 g = gasleft();
        (uint8 o, uint16 b,) = _chk(c, _rc(req, resp, DS_TEE, _teeSig(TEE_PK, NearFixtures.DEEPSEEK, req, resp)));
        emit log_named_uint("gas full receipt check, DeepSeek provider-TEE ECDSA", g - gasleft());
        assertEq(o, 4);
        assertEq(b, 5000);
        // the DeepSeek lane does NOT accept the gateway key (lane.receiptKind = PROVIDER_TEE)
        bytes memory gwSig = _ecdsaSign(ver.signedText(1, NearFixtures.DEEPSEEK, sha256(req), sha256(resp)));
        vm.expectRevert(BotledNearVerifier.Signer_.selector);
        ver.check(c, _rc(req, resp, GW_ECDSA, gwSig));
    }

    function testKimiLaneRejectsTeeKey() public {
        _deploy();
        (INearVerifier.Ctx memory c, bytes memory req, bytes memory resp) =
            _fixture(address(0xBEEF), keccak256("case"), NearFixtures.KIMI, "MUTUAL", 5000);
        bytes memory sig = _teeSig(TEE_PK, NearFixtures.KIMI, req, resp);
        vm.expectRevert(BotledNearVerifier.Signer_.selector);
        ver.check(c, _rc(req, resp, DS_TEE, sig));
    }

    function testTeeKeyRotationIsTimelockedAndModelBound() public {
        _deploy();
        (INearVerifier.Ctx memory c, bytes memory req, bytes memory resp) = _dsFixture();
        uint32 id = _proposeTee(0x7EF, NearFixtures.DEEPSEEK);
        bytes memory sig = _teeSig(0x7EF, NearFixtures.DEEPSEEK, req, resp);
        vm.expectRevert(BotledNearVerifier.Signer_.selector);
        ver.check(c, _rc(req, resp, id, sig));
        vm.warp(block.timestamp + 1 days);
        _chk(c, _rc(req, resp, id, sig));
        // a key bound to another model (e.g. the abliterated variant served from the same TEE) is rejected
        uint32 wrong = _proposeTee(0x7F0, "deepseek-ai/DeepSeek-V4.1-Flash-1017-abliterated");
        vm.warp(block.timestamp + 1 days);
        sig = _teeSig(0x7F0, NearFixtures.DEEPSEEK, req, resp);
        vm.expectRevert(BotledNearVerifier.Signer_.selector);
        ver.check(c, _rc(req, resp, wrong, sig));
    }

    // ================================================================ REAL NEAR AI chat receipts (test/near-vectors/real)

    /// @dev Produced by runner-near/tools/fetch-real-receipt.ts with a real API key, in the exact canonical layout for
    ///      VECTOR_CASE. Logged as skipped while the vector files are absent.
    // REAL paid receipts (runner-near/tools/fetch-real-receipt.ts, 2026-11-20). Keys are PINNED, not read from the file.
    // DeepSeek-V4.1-Flash-1017 TEE keys from GET /v1/attestation/report?model=deepseek-ai/DeepSeek-V4.1-Flash-1017.
    address constant DS_TEE_ECDSA = 0xfe0071895500A9755C18044948AB4f4e1A7f337e;
    bytes32 constant DS_TEE_ED25519 = 0x236f5a6b91dd47dc3b7b36e43d4eb531a042ffb8f8fbf3a1555b78cef4fdda4c;
    uint256 constant DS_WX = 17434810981884461409275962346463205779709739437501424370853330652094074868461;
    uint256 constant DS_WY = 22810675813067226280537522601436914280248282412383173995532820579254066382470;

    function testRealChatReceipts() public {
        _realLane("kimi", 0, false);
        _realLane("kimi", 0, true);
        _realLane("deepseek", 1, false);
        _realLane("deepseek", 1, true);
    }

    function _realCfg(uint8 laneIdx, bool ed25519) internal {
        BotledNearConfig.Signer[] memory s = new BotledNearConfig.Signer[](1);
        s[0].kind = laneIdx == 0 ? 1 : 2;
        if (laneIdx == 1) s[0].modelHash = keccak256(NearFixtures.DEEPSEEK);
        if (ed25519) {
            s[0].scheme = 2;
            s[0].edKey = laneIdx == 0 ? _gwKey() : [DS_WX, DS_WY, 0, 0, uint256(DS_TEE_ED25519)];
        } else {
            s[0].scheme = 1;
            s[0].ecdsa = laneIdx == 0 ? GATEWAY_ECDSA : DS_TEE_ECDSA;
        }
        BotledNearConfig.Lane[] memory l = new BotledNearConfig.Lane[](2);
        l[0] = _lane(NearFixtures.KIMI, "moonshotai", 1);
        l[1] = _lane(NearFixtures.DEEPSEEK, "deepseek", 2);
        BotledNearConfig.Template memory t;
        t.systemPromptHash = keccak256(systemPrompt);
        cfg = new BotledNearConfig(address(this), 1 days, s, t, l, address(0xE11));
        ver = new BotledNearVerifier(address(cfg));
    }

    function _realCtx(uint8 laneIdx) internal view returns (INearVerifier.Ctx memory c) {
        (bytes32 uh, uint32 ul) = ver.userBinding(VSCOPE, VPOSTER, VWORKER);
        c = INearVerifier.Ctx(0, laneIdx, VRUNNER, 1, VINPUT, uh, ul);
    }

    function _realLane(string memory name, uint8 laneIdx, bool ed25519) internal {
        string memory base = string.concat("test/near-vectors/real/", name);
        if (!vm.exists(string.concat(base, ".receipt.json"))) {
            emit log_named_string("real receipt vector missing (skipped)", name);
            return;
        }
        string memory meta = vm.readFile(string.concat(base, ".receipt.json"));
        _realCfg(laneIdx, ed25519);
        INearVerifier.Receipt memory rc = _rc(
            vm.readFileBinary(string.concat(base, ".request.json")),
            vm.readFileBinary(string.concat(base, ".response.json")),
            0,
            vm.parseJsonBytes(meta, ed25519 ? ".signatures.ed25519.signature" : ".signatures.ecdsa.signature")
        );
        INearVerifier.Ctx memory ctx = _realCtx(laneIdx);
        uint256 g = gasleft();
        (uint8 o, uint16 b,) = _chk(ctx, rc);
        emit log_named_uint(string.concat("gas REAL receipt check ", name, ed25519 ? " ed25519" : " ecdsa"), g - gasleft());
        assertEq(o, 2, "real ruling WORKER_WINS");
        assertEq(b, 10_000);
        // the same real receipt must not pass for the other lane (key class / model binding)
        INearVerifier.Ctx memory other = _realCtx(laneIdx ^ 1);
        vm.expectRevert();
        this.realCheck(other, rc);
    }

    function realCheck(INearVerifier.Ctx memory c, INearVerifier.Receipt memory rc) external view {
        ver.check(c, rc);
    }

    address constant VRUNNER = 0x1111111111111111111111111111111111111111;
    bytes32 constant VINPUT = 0x2222222222222222222222222222222222222222222222222222222222222222;
    bytes constant VSCOPE = "Build /refund.";
    bytes constant VPOSTER = "Poster: delivery misses the /refund endpoint that the scope requires.";
    bytes constant VWORKER = "Worker: commit 9f2c implements /refund; see tests/refund.spec.ts (41/41 green).\nDeadline met.";

    function testRegistryChangesAreTimelocked() public {
        _deploy();
        assertTrue(cfg.isSignerActive(0));
        cfg.scheduleSignerRetirement(0);
        assertTrue(cfg.isSignerActive(0), "retirement not instant");
        vm.warp(block.timestamp + 1 days);
        assertFalse(cfg.isSignerActive(0));
        // bad ed25519 key rejected at proposal
        BotledNearConfig.Signer memory s;
        s.scheme = 2;
        s.kind = 1;
        s.edKey = _gwKey();
        s.edKey[0] += 1;
        vm.expectRevert(BotledNearConfig.Config.selector);
        cfg.proposeSigner(s);
        // real gateway key accepted, active one timelock later
        s.edKey = _gwKey();
        uint32 id = cfg.proposeSigner(s);
        assertFalse(cfg.isSignerActive(id));
        vm.warp(block.timestamp + 1 days);
        assertTrue(cfg.isSignerActive(id));
        // only owner
        vm.prank(address(0xBAD));
        vm.expectRevert();
        cfg.proposeSigner(s);
        // enroll signer rotation timelocked
        cfg.proposeEnrollSigner(address(0xE12));
        vm.expectRevert(BotledNearConfig.Timelocked.selector);
        cfg.activateEnrollSigner();
        vm.warp(block.timestamp + 1 days);
        cfg.activateEnrollSigner();
        assertEq(cfg.enrollSigner(), address(0xE12));
    }

    function testTemplateNeedsDistinctProviders() public {
        _deploy();
        BotledNearConfig.Lane[] memory l = new BotledNearConfig.Lane[](2);
        l[0] = _lane(NearFixtures.KIMI, "moonshotai", 1);
        l[1] = _lane("moonshotai/kimi-k2.6", "moonshotai", 1);
        BotledNearConfig.Template memory t;
        t.systemPromptHash = keccak256(systemPrompt);
        vm.expectRevert(BotledNearConfig.Config.selector);
        cfg.proposeTemplate(t, l);
    }
}
