// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title BotledEvidence — permanent, account-free evidence hosting on Base
/// @notice Anyone publishes a UTF-8 document; it lives in the event log forever. The Azzle evidence hash is
///         keccak256(document), so a runner looks up `publishedAt(hash)` and reads the single matching log
///         from that block, then re-hashes the bytes. No admin, no storage of the document, no upgrade.
contract BotledEvidence {
    event Published(bytes32 indexed hash, address indexed publisher, bytes document);

    /// @notice Block of the first publication of `hash` (0 = never published).
    mapping(bytes32 => uint256) public publishedAt;

    function publish(bytes calldata document) external returns (bytes32 h) {
        require(document.length != 0, "BE: empty");
        h = keccak256(document);
        if (publishedAt[h] == 0) publishedAt[h] = block.number;
        emit Published(h, msg.sender, document);
    }
}
