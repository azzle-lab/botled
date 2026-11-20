// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev Interfaces of BotledNearConfig / BotledNearVerifier. The cage, pool and factory only import these: the two
///      implementations link the vendored SCL ed25519 code, which compiles with the legacy pipeline (not via-IR).
interface INearConfig {
    struct Signer {
        uint8 scheme;
        uint8 kind;
        uint64 activeAt;
        uint64 retiredAt;
        address ecdsa;
        bytes32 modelHash;
        uint256[5] edKey;
    }

    struct Lane {
        bytes model;
        bytes32 provider;
        bytes32 headHash;
        bytes32 tailHash;
        uint32 headLen;
        uint32 tailLen;
        uint8 receiptKind;
    }

    function enrollSigner() external view returns (address);
    function isTemplateActive(uint32 id) external view returns (bool);
    function laneCount(uint32 id) external view returns (uint256);
    function lane(uint32 id, uint8 i) external view returns (Lane memory);
    function templateHash(uint32 id) external view returns (bytes32);
    function isSignerActive(uint32 id) external view returns (bool);
    function signer(uint32 id) external view returns (Signer memory);
    function sponsorDigest(address runner, uint8 round, bytes32 inputHash, bytes32 reqHash, bytes32 respHash)
        external
        view
        returns (bytes32);
}

interface INearVerifier {
    struct Ctx {
        uint32 templateId;
        uint8 lane;
        address runner;
        uint8 round;
        bytes32 inputHash;
        bytes32 userHash;
        uint32 userLen;
    }

    function nearConfig() external view returns (address);
    function userText(bytes memory scope, bytes memory posterDoc, bytes memory workerDoc) external pure returns (bytes memory);
    function signedText(uint8 kind, bytes memory model, bytes32 reqHash, bytes32 respHash) external pure returns (bytes memory);
    function userBinding(bytes calldata scope, bytes calldata posterDoc, bytes calldata workerDoc)
        external
        pure
        returns (bytes32 h, uint32 len);
    function userBindingChecked(
        bytes calldata scope,
        bytes calldata posterDoc,
        bytes calldata workerDoc,
        bytes32 scopeHash,
        bytes32 posterEv,
        bytes32 workerEv
    ) external pure returns (bytes32 h, uint32 len);
    function commitDigest(address cage, address arbitration, uint256 taskId, uint8 round, bytes32 commitment)
        external
        view
        returns (bytes32);
    function commitSigner(address cage, address arbitration, uint256 taskId, uint8 round, bytes32 commitment, bytes calldata sig)
        external
        view
        returns (address);
    function jurorLine(address runner, uint8 round, bytes32 inputHash) external pure returns (bytes memory);
    struct Receipt {
        bytes request;         // exact request body bytes sent to NEAR AI
        bytes response;        // exact response body bytes received
        uint32 signerId;       // NEAR AI key (BotledNearConfig signer, class = lane.receiptKind)
        bytes signature;       // ECDSA 65 bytes (primary) or ed25519 64 bytes (fallback)
        uint32 sponsorId;      // sponsor relay key (KIND_SPONSOR); ignored when sponsorSig is empty
        bytes sponsorSig;      // empty = runner's own NEAR AI key: liveness only, not counted as a vote
    }

    function check(Ctx calldata c, Receipt calldata rc)
        external
        view
        returns (uint8 outcome, uint16 bps, bytes32 reqHash, bytes32 respHash, bool sponsored);
}
