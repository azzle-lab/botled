// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Ed25519} from "./lib/Ed25519.sol";

/// @title BotledNearConfig — timelocked registry of NEAR AI signing keys, pinned request templates and the
///        NEAR enrollment signer (Botled v5 / NEAR)
/// @notice Nothing here can rule, pick runners or move funds. Every ADDITION and every RETIREMENT is timelocked
///         (>= 1 day, same rule as BotledConfig), so a key rotation is public for a full timelock before it bites
///         and nobody — not even the owner — can switch a key or a template instantly. Genesis entries passed to the
///         constructor are active at deploy (public in the deploy tx).
///
///         Signer  = one NEAR AI response-signing identity:
///                   scheme ECDSA   -> EIP-191 signer address   (/v1/attestation/report?signing_algo=ecdsa)
///                   scheme ED25519 -> raw ed25519 key          (/v1/attestation/report?signing_algo=ed25519)
///                   kind GATEWAY      -> signs "<sha256(req)>:<sha256(resp)>"           (any model)
///                   kind PROVIDER_TEE -> signs "<model>:<sha256(req)>:<sha256(resp)>"   (only `modelHash`)
///                   kind SPONSOR      -> a Botled sponsor relay key (ECDSA only). It co-signs
///                                        SponsoredRun(runner, round, inputHash, sha256(req), sha256(resp)) for the ONE
///                                        request it ran for that juror seat. Only sponsored reveals are counted as votes.
///                                        Two different co-signed runs for the same seat retire the key immediately
///                                        (`reportEquivocation`, permissionless).
///         Lane.receiptKind pins which NEAR AI key class may sign that lane's responses: GATEWAY for models served
///         by third parties (kimi-k3 at Chutes), PROVIDER_TEE for NEAR-hosted TEE models (DeepSeek-V4.1-Flash-1017),
///         whose key is additionally bound to the lane model through `modelHash`.
///         Template = one constitution in NEAR form: per lane the exact request HEAD (model + system prompt up to
///                   the opening quote of the user content) and TAIL (closing of the user message + decoding +
///                   response_format). The case-specific middle is built on-chain by the cage.
contract BotledNearConfig is Ownable2Step {
    uint8 public constant SCHEME_ECDSA = 1;
    uint8 public constant SCHEME_ED25519 = 2;
    uint8 public constant KIND_GATEWAY = 1;
    uint8 public constant KIND_PROVIDER_TEE = 2;
    uint8 public constant KIND_SPONSOR = 3;
    bytes32 public constant SPONSOR_TYPEHASH =
        keccak256("SponsoredRun(address runner,uint8 round,bytes32 inputHash,bytes32 requestSha256,bytes32 responseSha256)");
    uint256 public constant MAX_LANES = 8;
    uint64 public constant MIN_TIMELOCK = 1 days;

    struct Signer {
        uint8 scheme;
        uint8 kind;
        uint64 activeAt;
        uint64 retiredAt;       // 0 = not scheduled
        address ecdsa;          // scheme ECDSA
        bytes32 modelHash;      // kind PROVIDER_TEE: keccak256(model id) the key is bound to; 0 for GATEWAY
        uint256[5] edKey;       // scheme ED25519: SCL extended key (see Ed25519.sol)
    }

    struct Lane {
        bytes model;            // canonical NEAR AI model id, e.g. "moonshotai/kimi-k3" (no alias)
        bytes32 provider;       // model company, e.g. "moonshotai" / "z-ai"; distinct per template
        bytes32 headHash;       // keccak256(head bytes)
        bytes32 tailHash;       // keccak256(tail bytes)
        uint32 headLen;
        uint32 tailLen;
        uint8 receiptKind;      // KIND_GATEWAY or KIND_PROVIDER_TEE: the only key class accepted for this lane
    }

    struct Template {
        bytes32 systemPromptHash; // keccak256 of the raw system prompt (documentation; enforced through headHash)
        bytes32 rubricHash;       // keccak256 of runner/constitution files bundle (documentation)
        uint64 activeAt;
    }

    uint64 public immutable timelock;

    Signer[] internal _signers;
    Template[] internal _templates;
    mapping(uint32 => Lane[]) internal _lanes;

    /// @notice EVM address of the NEAR MPC key (v1.signer) derived for (NEAR registry account, path).
    address public enrollSigner;
    address public pendingEnrollSigner;
    uint64 public pendingEnrollSignerEta;

    event SignerProposed(uint32 indexed id, uint8 scheme, uint8 kind, uint64 activeAt);
    event SignerRetirementScheduled(uint32 indexed id, uint64 retiredAt);
    event TemplateProposed(uint32 indexed id, uint64 activeAt, bytes32 hash);
    event EnrollSignerProposed(address signer, uint64 eta);
    event EnrollSignerActivated(address signer);
    event SponsorEquivocated(uint32 indexed id, address runner, uint8 round, bytes32 inputHash);

    error Config();
    error Timelocked();

    constructor(
        address owner_,
        uint64 timelock_,
        Signer[] memory genesisSigners,
        Template memory genesisTemplate,
        Lane[] memory genesisLanes,
        address enrollSigner_
    ) Ownable(owner_) {
        if (timelock_ < MIN_TIMELOCK || enrollSigner_ == address(0)) revert Config();
        timelock = timelock_;
        for (uint256 i; i < genesisSigners.length; ++i) _addSigner(genesisSigners[i], uint64(block.timestamp));
        _addTemplate(genesisTemplate, genesisLanes, uint64(block.timestamp));
        enrollSigner = enrollSigner_;
        emit EnrollSignerActivated(enrollSigner_);
    }

    // ---------------------------------------------------------------- signers

    function proposeSigner(Signer calldata s) external onlyOwner returns (uint32) {
        return _addSigner(s, uint64(block.timestamp) + timelock);
    }

    /// @notice Retirement is timelocked too: a compromised NEAR AI key is retired after `timelock`, never instantly
    ///         (instant removal would be a guardian power that can stall every running case).
    function scheduleSignerRetirement(uint32 id) external onlyOwner {
        Signer storage s = _signers[id];
        uint64 at = uint64(block.timestamp) + timelock;
        if (s.retiredAt != 0 && s.retiredAt <= at) revert Config();
        s.retiredAt = at;
        emit SignerRetirementScheduled(id, at);
    }

    function _addSigner(Signer memory s, uint64 activeAt) internal returns (uint32 id) {
        if (s.scheme == SCHEME_ECDSA) {
            if (s.ecdsa == address(0)) revert Config();
        } else if (s.scheme == SCHEME_ED25519) {
            if (!Ed25519.isExtKey(s.edKey)) revert Config();
        } else {
            revert Config();
        }
        if (s.kind == KIND_GATEWAY || s.kind == KIND_SPONSOR) {
            if (s.modelHash != 0 || (s.kind == KIND_SPONSOR && s.scheme != SCHEME_ECDSA)) revert Config();
        } else if (s.kind == KIND_PROVIDER_TEE) {
            if (s.modelHash == 0) revert Config();
        } else {
            revert Config();
        }
        s.activeAt = activeAt;
        s.retiredAt = 0;
        id = uint32(_signers.length);
        _signers.push(s);
        emit SignerProposed(id, s.scheme, s.kind, activeAt);
    }

    function signer(uint32 id) external view returns (Signer memory) { return _signers[id]; }
    function signerCount() external view returns (uint256) { return _signers.length; }

    function isSignerActive(uint32 id) public view returns (bool) {
        if (id >= _signers.length) return false;
        Signer storage s = _signers[id];
        return block.timestamp >= s.activeAt && (s.retiredAt == 0 || block.timestamp < s.retiredAt);
    }

    // ---------------------------------------------------------------- sponsor relay

    /// @notice What a sponsor relay signs (EIP-191 over this EIP-712-style struct hash, bound to chain + this config).
    function sponsorDigest(address runner, uint8 round, bytes32 inputHash, bytes32 reqHash, bytes32 respHash)
        public
        view
        returns (bytes32)
    {
        return MessageHashUtils.toEthSignedMessageHash(
            keccak256(abi.encode(SPONSOR_TYPEHASH, block.chainid, address(this), runner, round, inputHash, reqHash, respHash))
        );
    }

    /// @notice Permissionless fraud proof: a sponsor key that co-signed two DIFFERENT runs for the same juror seat
    ///         (= resampled) is retired at once. Not a guardian power: it needs the key's own two signatures.
    function reportEquivocation(
        uint32 id,
        address runner,
        uint8 round,
        bytes32 inputHash,
        bytes32[2] calldata reqHash,
        bytes32[2] calldata respHash,
        bytes calldata sigA,
        bytes calldata sigB
    ) external {
        Signer storage s = _signers[id];
        if (s.kind != KIND_SPONSOR || (reqHash[0] == reqHash[1] && respHash[0] == respHash[1])) revert Config();
        if (
            ECDSA.recover(sponsorDigest(runner, round, inputHash, reqHash[0], respHash[0]), sigA) != s.ecdsa
                || ECDSA.recover(sponsorDigest(runner, round, inputHash, reqHash[1], respHash[1]), sigB) != s.ecdsa
        ) revert Config();
        if (s.retiredAt == 0 || s.retiredAt > block.timestamp) s.retiredAt = uint64(block.timestamp);
        emit SponsorEquivocated(id, runner, round, inputHash);
    }

    // ---------------------------------------------------------------- templates (constitutions)

    function proposeTemplate(Template calldata t, Lane[] calldata lanes_) external onlyOwner returns (uint32) {
        return _addTemplate(t, lanes_, uint64(block.timestamp) + timelock);
    }

    function _addTemplate(Template memory t, Lane[] memory lanes_, uint64 activeAt) internal returns (uint32 id) {
        if (t.systemPromptHash == 0 || lanes_.length == 0 || lanes_.length > MAX_LANES) revert Config();
        id = uint32(_templates.length);
        for (uint256 i; i < lanes_.length; ++i) {
            Lane memory l = lanes_[i];
            if (
                l.model.length == 0 || l.provider == 0 || l.headHash == 0 || l.tailHash == 0 || l.headLen == 0 || l.tailLen == 0
                    || (l.receiptKind != KIND_GATEWAY && l.receiptKind != KIND_PROVIDER_TEE)
            ) {
                revert Config();
            }
            for (uint256 j; j < i; ++j) if (lanes_[j].provider == l.provider) revert Config(); // distinct companies
            _lanes[id].push(l);
        }
        t.activeAt = activeAt;
        _templates.push(t);
        emit TemplateProposed(id, activeAt, templateHash(id));
    }

    function isTemplateActive(uint32 id) external view returns (bool) {
        return id < _templates.length && block.timestamp >= _templates[id].activeAt;
    }

    function template(uint32 id) external view returns (Template memory) { return _templates[id]; }
    function lanes(uint32 id) external view returns (Lane[] memory) { return _lanes[id]; }
    function lane(uint32 id, uint8 i) external view returns (Lane memory) { return _lanes[id][i]; }
    function laneCount(uint32 id) external view returns (uint256) { return _lanes[id].length; }

    /// @notice Bound into every case's inputHash (replaces BotledConfig.constitutionHash for v5/NEAR cages).
    function templateHash(uint32 id) public view returns (bytes32) {
        Template storage t = _templates[id];
        return keccak256(abi.encode(t.systemPromptHash, t.rubricHash, _lanes[id]));
    }

    // ---------------------------------------------------------------- NEAR enrollment signer

    function proposeEnrollSigner(address s) external onlyOwner {
        if (s == address(0)) revert Config();
        pendingEnrollSigner = s;
        pendingEnrollSignerEta = uint64(block.timestamp) + timelock;
        emit EnrollSignerProposed(s, pendingEnrollSignerEta);
    }

    function activateEnrollSigner() external {
        if (pendingEnrollSignerEta == 0 || block.timestamp < pendingEnrollSignerEta) revert Timelocked();
        enrollSigner = pendingEnrollSigner;
        pendingEnrollSigner = address(0);
        pendingEnrollSignerEta = 0;
        emit EnrollSignerActivated(enrollSigner);
    }
}
