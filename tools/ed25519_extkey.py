#!/usr/bin/env python3
"""Compute the SCL (Smoo.th CryptoLib) extended public key for an ed25519 public key.

extKpub = [Wx, Wy, 0, 0, KpubC]
  (Wx, Wy) = the key's point on Wei25519 (short Weierstrass form used by SCL)
  KpubC    = the 32 raw public-key bytes read as a big-endian uint256 (what SCL hashes)
Only [0], [1] and [4] are read by SCL_EIP6565.Verify_LE; BotledNearConfig re-checks the mapping on-chain.
Usage: ed25519_extkey.py <64-hex public key>  -> prints 5 decimal integers, comma separated
"""
import sys

p = 2**255 - 19
d = (-121665 * pow(121666, p - 2, p)) % p
delta = 0x2aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaad2451
c = 0x70d9120b9f5ff9442d84f723fc03b0813a5e2c2eb482e57d3391fb5500ba81e7
sqrtm1 = pow(2, (p - 1) // 4, p)


def decompress(raw: bytes):
    v = int.from_bytes(raw, "little")
    sign = v >> 255
    y = v & ((1 << 255) - 1)
    if y >= p:
        raise ValueError("y out of range")
    x2 = (y * y - 1) * pow(d * y * y + 1, p - 2, p) % p
    x = pow(x2, (p + 3) // 8, p)
    if (x * x - x2) % p != 0:
        x = x * sqrtm1 % p
    if (x * x - x2) % p != 0:
        raise ValueError("not on curve")
    if x == 0 and sign:
        raise ValueError("bad sign")
    if x & 1 != sign:
        x = p - x
    return x, y


def ext_key(hexkey: str):
    raw = bytes.fromhex(hexkey.removeprefix("0x"))
    assert len(raw) == 32
    x, y = decompress(raw)
    wx = (delta + (1 + y) * pow((1 - y) % p, p - 2, p)) % p
    wy = c * (1 + y) % p * pow((1 - y) % p * x % p, p - 2, p) % p
    return [wx, wy, 0, 0, int.from_bytes(raw, "big")]


if __name__ == "__main__":
    print(",".join(str(v) for v in ext_key(sys.argv[1])))
