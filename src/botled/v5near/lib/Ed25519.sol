// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SCL_EIP6565} from "@solidity/lib/libSCL_EIP6565.sol";
import {ec_isOnCurve} from "@solidity/elliptic/SCL_ecOncurve.sol";
import {p, a, b} from "@solidity/fields/SCL_wei25519.sol";
import {SCL_sha512} from "@solidity/hash/SCL_sha512.sol";

/// @title Ed25519 — RFC 8032 signature check for NEAR AI receipts on Base (no precompile)
/// @notice Thin wrapper around the Smoo.th CryptoLib (SCL) EIP-6565 verifier, vendored unmodified from
///         get-smooth/crypto-lib (commit cc24ee4) (Veridise audit, Sep 2024, 0 residual findings).
/// @dev    An extended key is [Wx, Wy, -, -, KpubC]: the key as a point on Wei25519 plus the 32 raw key bytes
///         read big-endian. tools/ed25519_extkey.py computes it; `isExtKey` re-checks it on-chain.
library Ed25519 {
    /// @param message  exact signed bytes (NEAR AI: the UTF-8 `text` of /v1/signature)
    /// @param sig      64 raw signature bytes R || S (as returned hex-decoded by NEAR AI)
    function verify(bytes memory message, bytes memory sig, uint256[5] memory extKey) internal view returns (bool) {
        if (sig.length != 64) return false;
        uint256 r;
        uint256 s;
        assembly {
            r := mload(add(sig, 0x20))
            s := mload(add(sig, 0x40))
        }
        return SCL_EIP6565.Verify_LE(string(message), r, s, extKey);
    }

    /// @notice True iff (extKey[0], extKey[1]) is on Wei25519 and maps to the raw key bytes extKey[4].
    function isExtKey(uint256[5] memory extKey) internal view returns (bool) {
        if (!ec_isOnCurve(p, a, b, extKey[0], extKey[1])) return false;
        (uint256 x, uint256 y) = SCL_EIP6565.WeierStrass2Edwards(extKey[0], extKey[1]);
        uint256[2] memory e = [x, y];
        return SCL_sha512.Swap256(SCL_EIP6565.edCompress(e)) == extKey[4];
    }

    /// @notice keccak-free 32-byte id of an ed25519 key (= its raw bytes).
    function rawKey(uint256[5] memory extKey) internal pure returns (bytes32) {
        return bytes32(extKey[4]);
    }
}
