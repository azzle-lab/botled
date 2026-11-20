//! Host-provided primitives. The NEAR contract plugs in `env::*`; tests plug in sha2/sha3/k256/ed25519-dalek.

pub trait Crypto {
    fn sha256(&self, data: &[u8]) -> [u8; 32];
    fn keccak256(&self, data: &[u8]) -> [u8; 32];
    fn ed25519_verify(&self, sig: &[u8; 64], msg: &[u8], pk: &[u8; 32]) -> bool;
    /// Uncompressed public key (x || y) for a prehashed secp256k1 signature, `v` in {0, 1}.
    fn ecrecover(&self, hash: &[u8; 32], rs: &[u8; 64], v: u8) -> Option<[u8; 64]>;
}

/// secp256k1 n / 2, big-endian. Signatures with a higher `s` are rejected (EIP-2), matching the Base side.
const HALF_N: [u8; 32] = [
    0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x5d, 0x57, 0x6e, 0x73,
    0x57, 0xa4, 0x50, 0x1d, 0xdf, 0xe9, 0x2f, 0x46, 0x68, 0x1b, 0x20, 0xa0,
];

pub fn hex(bytes: &[u8]) -> String {
    const D: &[u8; 16] = b"0123456789abcdef";
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        s.push(D[(b >> 4) as usize] as char);
        s.push(D[(b & 15) as usize] as char);
    }
    s
}

pub fn unhex(s: &str) -> Result<Vec<u8>, &'static str> {
    let s = s.strip_prefix("0x").unwrap_or(s);
    if s.len() % 2 != 0 {
        return Err("bad hex");
    }
    let nib = |c: u8| -> Result<u8, &'static str> {
        match c {
            b'0'..=b'9' => Ok(c - b'0'),
            b'a'..=b'f' => Ok(c - b'a' + 10),
            b'A'..=b'F' => Ok(c - b'A' + 10),
            _ => Err("bad hex"),
        }
    };
    s.as_bytes().chunks(2).map(|p| Ok(nib(p[0])? << 4 | nib(p[1])?)).collect()
}

pub fn unhex_n<const N: usize>(s: &str) -> Result<[u8; N], &'static str> {
    unhex(s)?.try_into().map_err(|_| "bad hex length")
}

pub fn eth_address(c: &impl Crypto, pk: &[u8; 64]) -> [u8; 20] {
    let h = c.keccak256(pk);
    let mut a = [0u8; 20];
    a.copy_from_slice(&h[12..]);
    a
}

/// EIP-191 personal_sign hash of `msg`.
pub fn personal_hash(c: &impl Crypto, msg: &[u8]) -> [u8; 32] {
    let mut buf = format!("\x19Ethereum Signed Message:\n{}", msg.len()).into_bytes();
    buf.extend_from_slice(msg);
    c.keccak256(&buf)
}

/// Recovers the signer of a 65-byte `r || s || v` signature (v in {0, 1, 27, 28}); rejects high-s.
pub fn recover(c: &impl Crypto, hash: &[u8; 32], sig: &[u8]) -> Option<[u8; 20]> {
    if sig.len() != 65 {
        return None;
    }
    let mut rs = [0u8; 64];
    rs.copy_from_slice(&sig[..64]);
    if rs[32..] > HALF_N[..] {
        return None;
    }
    let v = match sig[64] {
        0 | 27 => 0,
        1 | 28 => 1,
        _ => return None,
    };
    c.ecrecover(hash, &rs, v).map(|pk| eth_address(c, &pk))
}

pub fn recover_personal(c: &impl Crypto, msg: &[u8], sig: &[u8]) -> Option<[u8; 20]> {
    recover(c, &personal_hash(c, msg), sig)
}
