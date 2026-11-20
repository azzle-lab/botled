// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {INearConfig, INearVerifier} from "./interfaces/IBotledNear.sol";
import {Ed25519} from "./lib/Ed25519.sol";
import {JsonText} from "./lib/JsonText.sol";
import {RulingParser} from "./lib/RulingParser.sol";

/// @title BotledNearVerifier — "this vote is the output of the pinned model for this exact case and juror"
/// @notice Stateless, no owner, no upgrade. Keys and templates come from the timelocked BotledNearConfig.
///
///         Request bytes (what the runner POSTs to https://cloud-api.near.ai/v1/chat/completions, byte-exact):
///           HEAD(lane)   {"model":"<model>","messages":[{"role":"system","content":"<system, escaped>"},{"role":"user","content":"
///           JUROR LINE   botled juror 0x<runner> round <r> case 0x<inputHash>\n            (the \n escaped: 2 bytes)
///           USER(case)   escape("<task_scope>\n" scope "\n</task_scope>\n<poster_evidence>\n" poster
///                               "\n</poster_evidence>\n<worker_evidence>\n" worker "\n</worker_evidence>\nReturn the JSON ruling now.")
///           TAIL(lane)   "}],"temperature":0,...,"n":1,"stream":false,"response_format":{...}}
///         HEAD/TAIL are pinned per lane by hash in BotledNearConfig (model id, constitution system prompt, decoding,
///         schema). USER is bound once per case on-chain from the Azzle evidence hashes (cage.bindEvidence). The
///         JUROR LINE makes every receipt unique to (runner, round, case): a receipt can never be copied from
///         another juror, another round or another case.
///         Response: the signature covers sha256(exact response bytes); RulingParser extracts the ruling.
contract BotledNearVerifier is INearVerifier {
    INearConfig internal immutable _nearConfig;

    error Layout();
    error Signer_();
    error Signature();
    error Ruling();
    error Evidence();
    error Sponsor();

    constructor(address nearConfig_) {
        _nearConfig = INearConfig(nearConfig_);
    }

    // ---------------------------------------------------------------- request pieces

    function userText(bytes memory scope, bytes memory posterDoc, bytes memory workerDoc) public pure returns (bytes memory) {
        return abi.encodePacked(
            "<task_scope>\n", scope, "\n</task_scope>\n<poster_evidence>\n", posterDoc,
            "\n</poster_evidence>\n<worker_evidence>\n", workerDoc, "\n</worker_evidence>\nReturn the JSON ruling now."
        );
    }

    /// @notice keccak256 of the escaped user text and its byte length (what the cage stores per case).
    function userBinding(bytes calldata scope, bytes calldata posterDoc, bytes calldata workerDoc)
        external
        pure
        returns (bytes32 h, uint32 len)
    {
        bytes memory esc = JsonText.escape(userText(scope, posterDoc, workerDoc));
        return (keccak256(esc), uint32(esc.length));
    }

    /// @notice userBinding after checking the raw documents against the hashes captured by the cage at openCase:
    ///         keccak256(doc) == Azzle evidence hash (empty doc for a zero hash); keccak256(scope) == scope hash
    ///         (empty scope when the cage has no scope source).
    function userBindingChecked(
        bytes calldata scope,
        bytes calldata posterDoc,
        bytes calldata workerDoc,
        bytes32 scopeHash,
        bytes32 posterEv,
        bytes32 workerEv
    ) external pure returns (bytes32 h, uint32 len) {
        if (!_docMatches(posterDoc, posterEv) || !_docMatches(workerDoc, workerEv)) revert Evidence();
        if (scopeHash == 0 ? scope.length != 0 : keccak256(scope) != scopeHash) revert Evidence();
        bytes memory esc = JsonText.escape(userText(scope, posterDoc, workerDoc));
        return (keccak256(esc), uint32(esc.length));
    }

    function _docMatches(bytes calldata doc, bytes32 h) internal pure returns (bool) {
        return h == 0 ? doc.length == 0 : keccak256(doc) == h;
    }

    bytes32 public constant COMMIT_TYPEHASH =
        keccak256("Commit(address arbitration,uint256 taskId,uint8 round,bytes32 commitment)");

    /// @notice EIP-712 digest a runner signs for a relayed commit (domain = the cage: name "BotledCageV5Near", "1").
    function commitDigest(address cage, address arbitration, uint256 taskId, uint8 round, bytes32 commitment)
        public
        view
        returns (bytes32)
    {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("BotledCageV5Near"), keccak256("1"), block.chainid, cage
            )
        );
        bytes32 h = keccak256(abi.encode(COMMIT_TYPEHASH, arbitration, taskId, round, commitment));
        return keccak256(abi.encodePacked("\x19\x01", domain, h));
    }

    /// @notice Signer of a relayed commit (address(0) if the signature is malformed or high-s).
    function commitSigner(address cage, address arbitration, uint256 taskId, uint8 round, bytes32 commitment, bytes calldata sig)
        external
        view
        returns (address)
    {
        (address a, ECDSA.RecoverError err,) = ECDSA.tryRecover(commitDigest(cage, arbitration, taskId, round, commitment), sig);
        return err == ECDSA.RecoverError.NoError ? a : address(0);
    }

    /// @notice Already in escaped form (ends with backslash + 'n').
    function jurorLine(address runner, uint8 round, bytes32 inputHash) public pure returns (bytes memory) {
        return abi.encodePacked(
            "botled juror ", JsonText.hexAddr(runner), " round ", JsonText.decimal(round), " case 0x", JsonText.hex32(inputHash), "\\n"
        );
    }

    /// @notice The exact UTF-8 text NEAR AI signs for this receipt.
    function signedText(uint8 kind, bytes memory model, bytes32 reqHash, bytes32 respHash) public pure returns (bytes memory) {
        bytes memory core = abi.encodePacked(JsonText.hex32(reqHash), ":", JsonText.hex32(respHash));
        return kind == 2 ? abi.encodePacked(model, ":", core) : core;
    }

    // ---------------------------------------------------------------- the check

    function nearConfig() external view returns (address) { return address(_nearConfig); }

    /// @notice Reverts unless (request, response, signature) is a valid NEAR AI receipt for this juror's case.
    ///         Returns the ruling inside the signed response and sha256 of the exact bytes (= what NEAR AI signed).
    function check(Ctx calldata c, Receipt calldata rc)
        external
        view
        returns (uint8 outcome, uint16 bps, bytes32 reqHash, bytes32 respHash, bool sponsored)
    {
        (reqHash, respHash) = _checkNearAi(c, rc);
        bool parsed;
        (parsed, outcome, bps) = RulingParser.parse(rc.response);
        if (!parsed) revert Ruling();
        if (rc.sponsorSig.length != 0) {
            _checkSponsor(c, rc.sponsorId, rc.sponsorSig, reqHash, respHash);
            sponsored = true;
        }
    }

    /// @dev layout + NEAR AI signature with the lane's key class
    function _checkNearAi(Ctx calldata c, Receipt calldata rc) internal view returns (bytes32 reqHash, bytes32 respHash) {
        INearConfig.Lane memory l = _nearConfig.lane(c.templateId, c.lane);
        _checkLayout(c, l, rc.request);
        reqHash = sha256(rc.request);
        respHash = sha256(rc.response);
        if (!_nearConfig.isSignerActive(rc.signerId)) revert Signer_();
        INearConfig.Signer memory s = _nearConfig.signer(rc.signerId);
        // per-lane key class; a provider-TEE key is also bound to exactly this lane's model
        if (s.kind != l.receiptKind || (s.kind == 2 && s.modelHash != keccak256(l.model))) revert Signer_();
        bytes memory text = signedText(s.kind, l.model, reqHash, respHash);
        bool ok = s.scheme == 1 ? _ecdsaOk(text, rc.signature, s.ecdsa) : Ed25519.verify(text, rc.signature, s.edKey);
        if (!ok) revert Signature();
    }

    function _checkSponsor(Ctx calldata c, uint32 id, bytes calldata sig, bytes32 reqHash, bytes32 respHash) internal view {
        if (!_nearConfig.isSignerActive(id)) revert Sponsor();
        INearConfig.Signer memory sp = _nearConfig.signer(id);
        bytes32 d = _nearConfig.sponsorDigest(c.runner, c.round, c.inputHash, reqHash, respHash);
        (address a, ECDSA.RecoverError err,) = ECDSA.tryRecover(d, sig);
        if (sp.kind != 3 || err != ECDSA.RecoverError.NoError || a != sp.ecdsa) revert Sponsor();
    }

    function _checkLayout(Ctx calldata c, INearConfig.Lane memory l, bytes calldata request) internal pure {
        bytes memory jl = jurorLine(c.runner, c.round, c.inputHash);
        uint256 a = l.headLen;
        uint256 b = a + jl.length;
        uint256 u = b + c.userLen;
        if (c.userHash == 0 || request.length != u + l.tailLen) revert Layout();
        if (keccak256(request[0:a]) != l.headHash) revert Layout();
        if (keccak256(request[a:b]) != keccak256(jl)) revert Layout();
        if (keccak256(request[b:u]) != c.userHash) revert Layout();
        if (keccak256(request[u:]) != l.tailHash) revert Layout();
    }

    /// @dev NEAR AI ecdsa receipts: EIP-191 personal_sign over `text`, 65-byte r||s||v (v 27/28 or 0/1). High-s rejected.
    function _ecdsaOk(bytes memory text, bytes calldata sig, address expected) internal pure returns (bool) {
        if (sig.length != 65 || expected == address(0)) return false;
        bytes32 r = bytes32(sig[0:32]);
        bytes32 s = bytes32(sig[32:64]);
        uint8 v = uint8(sig[64]);
        if (v < 27) v += 27;
        if (v != 27 && v != 28) return false;
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) return false;
        bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n", JsonText.decimal(text.length), text));
        return ecrecover(digest, v, r, s) == expected;
    }
}
