// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title RulingParser — reads (outcome, workerBps) out of a raw OpenAI-style chat.completion body
/// @notice The body is the exact byte string NEAR AI signed. We locate the ONE JSON key "content" and parse the
///         ruling object at the start of its (escaped) string value.
///
///         Why the key match is unambiguous: in raw JSON every '"' that is part of a string VALUE is escaped,
///         i.e. preceded by '\'. A '"' whose previous non-whitespace byte is '{' or ',' is therefore always a
///         structural quote that starts an object KEY. We require exactly one such `"content"` key in the whole
///         body (the request pins n=1, no tools, no logprobs), so `reasoning_content`, text inside the reasoning,
///         or text inside the ruling's own "reason" can never be mistaken for the answer.
///
///         Inside the content string the ruling JSON is escaped once: quotes are `\"`, model whitespace is raw
///         spaces or `\n` `\r` `\t` escapes. Accepted shape (schema order, either order of the first two keys):
///           {"outcome":"<POSTER_WINS|WORKER_WINS|SPLIT|MUTUAL|NONE>","workerBps":<0..10000>, ... }
///         Anything else -> ok = false (the runner retries the call; an unparseable answer cannot be revealed).
library RulingParser {
    uint8 internal constant NONE_ = 0;
    uint8 internal constant POSTER_WINS = 1;
    uint8 internal constant WORKER_WINS = 2;
    uint8 internal constant SPLIT = 3;
    uint8 internal constant MUTUAL = 4;

    // `"content"` = 22 63 6f 6e 74 65 6e 74 22 (9 bytes)
    uint256 private constant KEY = 0x22636f6e74656e7422;
    uint256 private constant L7 = 0x7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f;

    function parse(bytes calldata r) internal pure returns (bool ok, uint8 outcome, uint16 bps) {
        uint256 at = _findContentKey(r);
        if (at == type(uint256).max) return (false, 0, 0);
        uint256 i = at + 9;
        i = _rawWs(r, i);
        if (i >= r.length || r[i] != ":") return (false, 0, 0);
        i = _rawWs(r, i + 1);
        if (i >= r.length || r[i] != '"') return (false, 0, 0);
        i = _innerWs(r, i + 1);
        if (i >= r.length || r[i] != "{") return (false, 0, 0);
        i = _innerWs(r, i + 1);

        bool haveO;
        bool haveB;
        uint256 b;
        for (uint256 pair; pair < 2; ++pair) {
            bytes32 key;
            (ok, key, i) = _innerString(r, i);
            if (!ok) return (false, 0, 0);
            i = _innerWs(r, i);
            if (i >= r.length || r[i] != ":") return (false, 0, 0);
            i = _innerWs(r, i + 1);
            if (key == "outcome" && !haveO) {
                bytes32 v;
                (ok, v, i) = _innerString(r, i);
                if (!ok) return (false, 0, 0);
                if (v == "POSTER_WINS") outcome = POSTER_WINS;
                else if (v == "WORKER_WINS") outcome = WORKER_WINS;
                else if (v == "SPLIT") outcome = SPLIT;
                else if (v == "MUTUAL") outcome = MUTUAL;
                else if (v == "NONE") outcome = NONE_;
                else return (false, 0, 0);
                haveO = true;
            } else if (key == "workerBps" && !haveB) {
                uint256 digits;
                while (i < r.length && uint8(r[i]) >= 0x30 && uint8(r[i]) <= 0x39) {
                    if (digits == 0 && b == 0 && r[i] == "0" && i + 1 < r.length && uint8(r[i + 1]) >= 0x30 && uint8(r[i + 1]) <= 0x39) {
                        return (false, 0, 0); // leading zero
                    }
                    b = b * 10 + (uint8(r[i]) - 0x30);
                    if (++digits > 5) return (false, 0, 0);
                    ++i;
                }
                if (digits == 0 || b > 10_000) return (false, 0, 0);
                haveB = true;
            } else {
                return (false, 0, 0);
            }
            i = _innerWs(r, i);
            if (i >= r.length) return (false, 0, 0);
            bytes1 sep = r[i];
            if (sep == ",") i = _innerWs(r, i + 1);
            else if (!(sep == "}" && pair == 1)) return (false, 0, 0);
        }
        if (!(haveO && haveB)) return (false, 0, 0);
        return (true, outcome, uint16(b));
    }

    /// @dev position of the unique structural `"content"` key, or max if none / more than one.
    ///      Same semantics as a byte-by-byte scan, but 32 bytes per step: a word without any '"' (0x22) byte is
    ///      skipped with one SWAR test, so long `reasoning_content` prose costs ~40 gas per 32 bytes. Every '"' byte
    ///      is still examined, so uniqueness is checked over the WHOLE signed body (no hint from the submitter).
    function _findContentKey(bytes calldata r) private pure returns (uint256 found) {
        found = type(uint256).max;
        uint256 n = r.length;
        if (n < 10) return found;
        uint256 base;
        assembly {
            base := r.offset
        }
        unchecked {
            for (uint256 w0; w0 < n; w0 += 32) {
                uint256 w;
                assembly {
                    w := calldataload(add(base, w0))
                }
                uint256 left = n - w0;
                if (left < 32) w &= ~((uint256(1) << (8 * (32 - left))) - 1); // drop bytes past the body
                uint256 x = w ^ 0x2222222222222222222222222222222222222222222222222222222222222222;
                // exact per-byte zero test (no carries between bytes): bit 7 of byte b set <=> byte b of w == '"'
                uint256 m = ~(((x & L7) + L7) | x | L7);
                while (m != 0) {
                    uint256 b = _leadingZeroBytes(m);
                    m &= ~(uint256(0x80) << (8 * (31 - b)));
                    if (w0 + b >= n) break; // masked tail (never '"' after masking, kept for clarity)
                    uint256 i = w0 + b;
                    if (i == 0 || i + 9 > n) continue;
                    uint256 k;
                    assembly {
                        k := shr(184, calldataload(add(base, i)))
                    }
                    if (k != KEY) continue;
                    // previous non-whitespace byte must be '{' or ','
                    uint256 j = i;
                    bytes1 prev;
                    while (j > 0) {
                        prev = r[j - 1];
                        if (prev != " " && prev != "\n" && prev != "\r" && prev != "\t") break;
                        --j;
                    }
                    if (j == 0 || (prev != "{" && prev != ",")) continue;
                    if (found != type(uint256).max) return type(uint256).max; // ambiguous
                    found = i;
                }
            }
        }
    }

    /// @dev number of leading zero BYTES of m != 0 (m only has bits 7 of bytes set)
    function _leadingZeroBytes(uint256 m) private pure returns (uint256 n) {
        unchecked {
            if (m >> 128 == 0) { n += 16; m <<= 128; }
            if (m >> 192 == 0) { n += 8; m <<= 64; }
            if (m >> 224 == 0) { n += 4; m <<= 32; }
            if (m >> 240 == 0) { n += 2; m <<= 16; }
            if (m >> 248 == 0) { n += 1; }
        }
    }

    function _rawWs(bytes calldata r, uint256 i) private pure returns (uint256) {
        while (i < r.length && (r[i] == " " || r[i] == "\n" || r[i] == "\r" || r[i] == "\t")) ++i;
        return i;
    }

    /// @dev whitespace of the escaped inner JSON: raw ' ' or the escapes \n \r \t
    function _innerWs(bytes calldata r, uint256 i) private pure returns (uint256) {
        while (i < r.length) {
            if (r[i] == " ") { ++i; continue; }
            if (r[i] == "\\" && i + 1 < r.length && (r[i + 1] == "n" || r[i + 1] == "r" || r[i + 1] == "t")) { i += 2; continue; }
            break;
        }
        return i;
    }

    /// @dev escaped inner string \"[A-Za-z_]{1,32}\" -> left-aligned bytes32
    function _innerString(bytes calldata r, uint256 i) private pure returns (bool ok, bytes32 v, uint256 next) {
        if (i + 1 >= r.length || r[i] != "\\" || r[i + 1] != '"') return (false, 0, i);
        i += 2;
        uint256 start = i;
        while (i < r.length) {
            uint8 c = uint8(r[i]);
            bool word = (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a) || c == 0x5f;
            if (!word) break;
            ++i;
        }
        uint256 len = i - start;
        if (len == 0 || len > 32 || i + 1 >= r.length || r[i] != "\\" || r[i + 1] != '"') return (false, 0, i);
        bytes32 w = bytes32(r[start:i]);
        return (true, w, i + 2);
    }
}
