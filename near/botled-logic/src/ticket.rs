//! EIP-712 enrollment tickets for `BotledRunnerPoolNear.enroll` on Base, signed by the NEAR MPC key derived for
//! (registry account, ENROLL_PATH). Byte-identical to `enrollDigest` (vector in test/near/BotledV5Near.t.sol).

use borsh::{BorshDeserialize, BorshSerialize};
use serde::{Deserialize, Serialize};

use crate::crypto::Crypto;

pub const ENROLL_PATH: &str = "botled-enroll-v1";

#[derive(BorshSerialize, BorshDeserialize, Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
pub struct PoolDomain {
    pub chain_id: u64,
    pub pool: [u8; 20],
}

fn word_u64(x: u64) -> [u8; 32] {
    let mut w = [0u8; 32];
    w[24..].copy_from_slice(&x.to_be_bytes());
    w
}

fn word_addr(a: &[u8; 20]) -> [u8; 32] {
    let mut w = [0u8; 32];
    w[12..].copy_from_slice(a);
    w
}

pub fn near_account_hash(c: &impl Crypto, account: &str) -> [u8; 32] {
    c.keccak256(account.as_bytes())
}

pub fn domain_separator(c: &impl Crypto, d: &PoolDomain) -> [u8; 32] {
    let mut b = Vec::with_capacity(160);
    b.extend_from_slice(&c.keccak256(b"EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"));
    b.extend_from_slice(&c.keccak256(b"BotledRunnerPoolNear"));
    b.extend_from_slice(&c.keccak256(b"1"));
    b.extend_from_slice(&word_u64(d.chain_id));
    b.extend_from_slice(&word_addr(&d.pool));
    c.keccak256(&b)
}

pub fn enroll_digest(
    c: &impl Crypto,
    d: &PoolDomain,
    runner: &[u8; 20],
    near_account: &[u8; 32],
    epoch: u32,
    no_shows_covered: u32,
    valid_until: u64,
    session_key: &[u8; 20],
) -> [u8; 32] {
    let mut s = Vec::with_capacity(224);
    s.extend_from_slice(&c.keccak256(
        b"Enroll(address runner,bytes32 nearAccount,uint32 epoch,uint32 noShowsCovered,uint64 validUntil,address sessionKey)",
    ));
    s.extend_from_slice(&word_addr(runner));
    s.extend_from_slice(near_account);
    s.extend_from_slice(&word_u64(epoch as u64));
    s.extend_from_slice(&word_u64(no_shows_covered as u64));
    s.extend_from_slice(&word_u64(valid_until));
    s.extend_from_slice(&word_addr(session_key));
    let mut m = vec![0x19, 0x01];
    m.extend_from_slice(&domain_separator(c, d));
    m.extend_from_slice(&c.keccak256(&s));
    c.keccak256(&m)
}

/// What a Botled sponsor relay co-signs for the ONE run it made for a juror seat (BotledNearConfig.sponsorDigest):
/// EIP-191( keccak256(abi.encode(SPONSOR_TYPEHASH, chainId, nearConfig, runner, round, inputHash, reqSha, respSha)) ).
pub fn sponsor_digest(
    c: &impl Crypto,
    chain_id: u64,
    near_config: &[u8; 20],
    runner: &[u8; 20],
    round: u8,
    input_hash: &[u8; 32],
    req_sha: &[u8; 32],
    resp_sha: &[u8; 32],
) -> [u8; 32] {
    let mut b = Vec::with_capacity(256);
    b.extend_from_slice(&c.keccak256(
        b"SponsoredRun(address runner,uint8 round,bytes32 inputHash,bytes32 requestSha256,bytes32 responseSha256)",
    ));
    b.extend_from_slice(&word_u64(chain_id));
    b.extend_from_slice(&word_addr(near_config));
    b.extend_from_slice(&word_addr(runner));
    b.extend_from_slice(&word_u64(round as u64));
    b.extend_from_slice(input_hash);
    b.extend_from_slice(req_sha);
    b.extend_from_slice(resp_sha);
    let mut m = b"\x19Ethereum Signed Message:\n32".to_vec();
    m.extend_from_slice(&c.keccak256(&b));
    c.keccak256(&m)
}
