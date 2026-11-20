// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title JsonText — byte-exact JSON string escaping and hex helpers shared by the cage and the runner client
/// @notice escape() is the canonical escaper the runner MUST use when it builds the request body (byte-for-byte):
///           "  -> \"      \  -> \\      0x08 -> \b   0x0c -> \f   0x0a -> \n   0x0d -> \r   0x09 -> \t
///           other bytes < 0x20 -> \u00xx (lowercase hex);   every other byte (incl. UTF-8, '/', 0x7f) unchanged.
///         For valid UTF-8 input this equals JavaScript's JSON.stringify string body.
library JsonText {
    function escape(bytes memory s) internal pure returns (bytes memory out) {
        uint256 n = s.length;
        uint256 extra;
        for (uint256 i; i < n; ++i) {
            uint8 c = uint8(s[i]);
            if (c == 0x22 || c == 0x5c || c == 0x08 || c == 0x0c || c == 0x0a || c == 0x0d || c == 0x09) extra += 1;
            else if (c < 0x20) extra += 5;
        }
        if (extra == 0) return s;
        out = new bytes(n + extra);
        uint256 j;
        bytes16 hexd = "0123456789abcdef";
        for (uint256 i; i < n; ++i) {
            bytes1 ch = s[i];
            uint8 c = uint8(ch);
            if (c >= 0x20 && c != 0x22 && c != 0x5c) {
                out[j++] = ch;
                continue;
            }
            out[j++] = "\\";
            if (c == 0x22) out[j++] = '"';
            else if (c == 0x5c) out[j++] = "\\";
            else if (c == 0x08) out[j++] = "b";
            else if (c == 0x0c) out[j++] = "f";
            else if (c == 0x0a) out[j++] = "n";
            else if (c == 0x0d) out[j++] = "r";
            else if (c == 0x09) out[j++] = "t";
            else {
                out[j++] = "u";
                out[j++] = "0";
                out[j++] = "0";
                out[j++] = hexd[c >> 4];
                out[j++] = hexd[c & 0x0f];
            }
        }
    }

    /// @notice lowercase hex of 32 bytes, no 0x (64 chars)
    function hex32(bytes32 v) internal pure returns (bytes memory out) {
        out = new bytes(64);
        bytes16 hexd = "0123456789abcdef";
        for (uint256 i; i < 32; ++i) {
            uint8 c = uint8(v[i]);
            out[2 * i] = hexd[c >> 4];
            out[2 * i + 1] = hexd[c & 0x0f];
        }
    }

    /// @notice lowercase hex of an address WITH 0x (42 chars, not EIP-55)
    function hexAddr(address v) internal pure returns (bytes memory out) {
        out = new bytes(42);
        out[0] = "0";
        out[1] = "x";
        bytes16 hexd = "0123456789abcdef";
        bytes20 w = bytes20(v);
        for (uint256 i; i < 20; ++i) {
            uint8 c = uint8(w[i]);
            out[2 + 2 * i] = hexd[c >> 4];
            out[3 + 2 * i] = hexd[c & 0x0f];
        }
    }

    function decimal(uint256 v) internal pure returns (bytes memory out) {
        if (v == 0) return "0";
        uint256 len;
        for (uint256 t = v; t != 0; t /= 10) ++len;
        out = new bytes(len);
        for (; v != 0; v /= 10) out[--len] = bytes1(uint8(48 + v % 10));
    }
}
