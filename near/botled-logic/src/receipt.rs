//! NEAR AI receipts: `GET /v1/signature/{chat_id}` signatures over the exact request/response bytes.
//! gateway:      text = hex(sha256(request)) ":" hex(sha256(response))
//! provider_tee: text = model ":" hex(sha256(request)) ":" hex(sha256(response))
//! ecdsa = EIP-191 personal_sign over the text; ed25519 = signature over the UTF-8 text.

use borsh::{BorshDeserialize, BorshSerialize};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::crypto::{hex, recover_personal, Crypto};

#[derive(BorshSerialize, BorshDeserialize, Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
pub enum Scheme {
    Ecdsa,
    Ed25519,
}

#[derive(BorshSerialize, BorshDeserialize, Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Gateway,
    ProviderTee,
}

#[derive(BorshSerialize, BorshDeserialize, Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
pub struct SignerKey {
    pub scheme: Scheme,
    pub kind: Kind,
    /// 20-byte address (ecdsa) or 32-byte public key (ed25519)
    pub key: Vec<u8>,
    /// provider_tee keys sign for exactly one model
    pub model: Option<String>,
    pub active: bool,
}

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq, Default)]
pub struct Usage {
    pub prompt_tokens: u64,
    pub completion_tokens: u64,
}

/// What a verified receipt proves.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Verified {
    pub request_hash: [u8; 32],
    pub response_hash: [u8; 32],
    pub model: String,
    pub usage: Usage,
    /// class of the NEAR AI key that signed (must match the lane's receipt kind)
    pub kind: Kind,
    /// first line of the user message: `botled juror 0x<runner> round <r> case 0x<inputHash>`
    pub juror: Juror,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Juror {
    pub runner: [u8; 20],
    pub round: u8,
    pub case_hash: [u8; 32],
}

pub fn signed_text(kind: Kind, model: &str, req: &[u8; 32], resp: &[u8; 32]) -> String {
    let core = format!("{}:{}", hex(req), hex(resp));
    match kind {
        Kind::Gateway => core,
        Kind::ProviderTee => format!("{model}:{core}"),
    }
}

pub fn check_signature(c: &impl Crypto, key: &SignerKey, text: &[u8], sig: &[u8]) -> bool {
    match key.scheme {
        Scheme::Ecdsa => key.key.len() == 20 && recover_personal(c, text, sig).map(|a| a[..] == key.key[..]).unwrap_or(false),
        Scheme::Ed25519 => {
            let (Ok(pk), Ok(s)) = (<[u8; 32]>::try_from(&key.key[..]), <[u8; 64]>::try_from(sig)) else {
                return false;
            };
            c.ed25519_verify(&s, text, &pk)
        }
    }
}

/// Parses `botled juror 0x<40 hex> round <dec> case 0x<64 hex>\n...` (the juror line the Base cage pins).
pub fn parse_juror(user: &str) -> Result<Juror, &'static str> {
    let line = user.split('\n').next().ok_or("juror line")?;
    let p: Vec<&str> = line.split(' ').collect();
    if p.len() != 7 || p[0] != "botled" || p[1] != "juror" || p[3] != "round" || p[5] != "case" {
        return Err("juror line");
    }
    // the Base side emits lowercase hex only; accept nothing else so one run maps to one juror line
    let lower = |s: &str| s.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b));
    let (a, h) = (p[2].strip_prefix("0x").ok_or("juror line")?, p[6].strip_prefix("0x").ok_or("juror line")?);
    if a.len() != 40 || h.len() != 64 || !lower(a) || !lower(h) {
        return Err("juror line");
    }
    if p[4].is_empty() || (p[4].len() > 1 && p[4].starts_with('0')) {
        return Err("juror line");
    }
    Ok(Juror {
        runner: crate::crypto::unhex_n(a)?,
        round: p[4].parse().map_err(|_| "juror line")?,
        case_hash: crate::crypto::unhex_n(h)?,
    })
}

/// Verifies signature + structure and extracts model, usage and the juror line. Does NOT price or dedupe.
pub fn verify(c: &impl Crypto, key: &SignerKey, request: &[u8], response: &[u8], sig: &[u8]) -> Result<Verified, &'static str> {
    if !key.active {
        return Err("signer retired");
    }
    let req: Value = serde_json::from_slice(request).map_err(|_| "request json")?;
    let resp: Value = serde_json::from_slice(response).map_err(|_| "response json")?;
    let model = req["model"].as_str().ok_or("request model")?;
    if resp["model"].as_str() != Some(model) {
        return Err("response model");
    }
    if req["stream"].as_bool() == Some(true) {
        return Err("stream");
    }
    if key.kind == Kind::ProviderTee && key.model.as_deref() != Some(model) {
        return Err("signer model");
    }
    let msgs = req["messages"].as_array().ok_or("messages")?;
    let user = msgs.iter().find(|m| m["role"] == "user").and_then(|m| m["content"].as_str()).ok_or("user message")?;
    let juror = parse_juror(user)?;
    let u = &resp["usage"];
    let usage = Usage {
        prompt_tokens: u["prompt_tokens"].as_u64().ok_or("usage")?,
        completion_tokens: u["completion_tokens"].as_u64().ok_or("usage")?,
    };
    let (rq, rs) = (c.sha256(request), c.sha256(response));
    if !check_signature(c, key, signed_text(key.kind, model, &rq, &rs).as_bytes(), sig) {
        return Err("signature");
    }
    Ok(Verified { request_hash: rq, response_hash: rs, model: model.to_string(), usage, kind: key.kind, juror })
}
