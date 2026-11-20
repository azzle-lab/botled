//! NEAR Chain Signatures (v1.signer) key derivation, secp256k1 domain 0:
//!   tweak    = sha3_256("near-mpc-recovery v0.1.0 epsilon derivation:" || predecessor || "," || path)
//!   child_pk = root_pk + tweak * G
//!   address  = keccak256(x || y)[12..]
//! Enabled with feature `derivation` (k256 point math in wasm; gas to be measured on testnet).

use k256::elliptic_curve::sec1::{FromEncodedPoint, ToEncodedPoint};
use k256::elliptic_curve::PrimeField;
use k256::{AffinePoint, EncodedPoint, ProjectivePoint, Scalar};
use sha3::{Digest, Sha3_256};

pub const EPSILON_PREFIX: &str = "near-mpc-recovery v0.1.0 epsilon derivation:";

/// Mainnet v1.signer root key (domain 0).
pub const MAINNET_ROOT: &str =
    "secp256k1:3tFRbMqmoa6AAALMrEFAYCEoHcqKxeW38YptwowBVBtXK1vo36HDbUWuR6EZmoK4JcH6HDkNMGGqP1ouV7VZUWya";

pub fn parse_near_secp(s: &str) -> Result<[u8; 64], &'static str> {
    let b = bs58::decode(s.strip_prefix("secp256k1:").ok_or("prefix")?).into_vec().map_err(|_| "b58")?;
    b.try_into().map_err(|_| "len")
}

pub fn epsilon(predecessor: &str, path: &str) -> Result<Scalar, &'static str> {
    let h = Sha3_256::digest(format!("{EPSILON_PREFIX}{predecessor},{path}").as_bytes());
    Option::from(Scalar::from_repr(h)).ok_or("tweak")
}

pub fn derive_public_key(root: &[u8; 64], predecessor: &str, path: &str) -> Result<[u8; 64], &'static str> {
    let ep = EncodedPoint::from_untagged_bytes(root.into());
    let root: AffinePoint = Option::from(AffinePoint::from_encoded_point(&ep)).ok_or("root not on curve")?;
    let child = (ProjectivePoint::GENERATOR * epsilon(predecessor, path)? + ProjectivePoint::from(root)).to_affine();
    let enc = child.to_encoded_point(false);
    let mut out = [0u8; 64];
    out.copy_from_slice(&enc.as_bytes()[1..]);
    Ok(out)
}
