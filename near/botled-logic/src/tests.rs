use ed25519_dalek::{Signer as _, SigningKey as EdKey, Verifier as _};
use k256::ecdsa::{RecoveryId, Signature, SigningKey, VerifyingKey};
use sha2::Digest as _;

use crate::crypto::*;
use crate::receipt::*;
use crate::registry::*;
use crate::ticket::*;

pub struct Native;

impl Crypto for Native {
    fn sha256(&self, d: &[u8]) -> [u8; 32] {
        sha2::Sha256::digest(d).into()
    }
    fn keccak256(&self, d: &[u8]) -> [u8; 32] {
        sha3::Keccak256::digest(d).into()
    }
    fn ed25519_verify(&self, sig: &[u8; 64], msg: &[u8], pk: &[u8; 32]) -> bool {
        let Ok(k) = ed25519_dalek::VerifyingKey::from_bytes(pk) else { return false };
        k.verify(msg, &ed25519_dalek::Signature::from_bytes(sig)).is_ok()
    }
    fn ecrecover(&self, hash: &[u8; 32], rs: &[u8; 64], v: u8) -> Option<[u8; 64]> {
        let sig = Signature::from_slice(rs).ok()?;
        let k = VerifyingKey::recover_from_prehash(hash, &sig, RecoveryId::from_byte(v)?).ok()?;
        k.to_encoded_point(false).as_bytes()[1..].try_into().ok()
    }
}

const C: Native = Native;
const KIMI: &str = "moonshotai/kimi-k3";
const DS: &str = "deepseek-ai/DeepSeek-V4.1-Flash-1017";

fn key(n: u8) -> SigningKey {
    SigningKey::from_bytes(&[n; 32].into()).unwrap()
}

fn addr(k: &SigningKey) -> [u8; 20] {
    let pk: [u8; 64] = k.verifying_key().to_encoded_point(false).as_bytes()[1..].try_into().unwrap();
    eth_address(&C, &pk)
}

fn personal_sign(k: &SigningKey, msg: &[u8]) -> Vec<u8> {
    let (sig, rec) = k.sign_prehash_recoverable(&personal_hash(&C, msg)).unwrap();
    let mut out = sig.to_bytes().to_vec();
    out.push(27 + rec.to_byte());
    out
}

fn json_str(s: &str) -> String {
    serde_json::to_string(s).unwrap()
}

/// Same shape as test/near/NearFixtures.sol.
fn request(model: &str, runner: &[u8; 20], round: u8, case: &[u8; 32]) -> Vec<u8> {
    let user = format!("botled juror 0x{} round {round} case 0x{}\n<task_scope>\n\n</task_scope>\n...", hex(runner), hex(case));
    format!(
        r#"{{"model":"{model}","messages":[{{"role":"system","content":{}}},{{"role":"user","content":{}}}],"temperature":0,"seed":0,"max_tokens":1200,"n":1,"stream":false}}"#,
        json_str("You are a Botled juror."),
        json_str(&user)
    )
    .into_bytes()
}

fn response(model: &str, pt: u64, ct: u64) -> Vec<u8> {
    format!(
        r#"{{"id":"chatcmpl-7f3a","object":"chat.completion","model":"{model}","choices":[{{"index":0,"message":{{"role":"assistant","content":{}}},"finish_reason":"stop"}}],"usage":{{"prompt_tokens":{pt},"completion_tokens":{ct},"total_tokens":{}}}}}"#,
        json_str(r#"{"outcome":"SPLIT","workerBps":6500,"reason":"x"}"#),
        pt + ct
    )
    .into_bytes()
}

fn gateway() -> SigningKey {
    key(0x6a)
}

fn settings() -> Settings {
    Settings {
        params: Params::default(),
        usdc: "usdc.near".into(),
        profit_to: "profit.botled.near".into(),
        dev_to: "dev.botled.near".into(),
        penalty_to: "dev.botled.near".into(),
        lanes: vec![
            LanePrice { model: KIMI.into(), input_per_mtok: 3_300_000, output_per_mtok: 16_500_000, receipt_kind: Kind::Gateway },
            LanePrice { model: DS.into(), input_per_mtok: 300_000, output_per_mtok: 1_200_000, receipt_kind: Kind::ProviderTee },
        ],
        signers: vec![
            SignerKey { scheme: Scheme::Ecdsa, kind: Kind::Gateway, key: addr(&gateway()).to_vec(), model: None, active: true },
            SignerKey { scheme: Scheme::Ecdsa, kind: Kind::ProviderTee, key: addr(&key(0x7e)).to_vec(), model: Some(DS.into()), active: true },
        ],
        sponsors: vec!["relay.botled.near".into()],
        pool: PoolDomain { chain_id: 8453, pool: [0x33; 20] },
        reward_bridge: None,
    }
}

fn runner_with(base: [u8; 20], budget: u128) -> Runner {
    Runner { base, budget, spent: 0, penalties: 0, no_shows_charged: 0, epoch: 0, runs: 0, ticket_until: 0, status: Status::Active }
}

fn signed_receipt(model: &str, runner: &[u8; 20]) -> (Vec<u8>, Vec<u8>, Vec<u8>) {
    let (rq, rs) = (request(model, runner, 1, &[0xcc; 32]), response(model, 3120, 912));
    let text = signed_text(Kind::Gateway, model, &C.sha256(&rq), &C.sha256(&rs));
    let sig = personal_sign(&gateway(), text.as_bytes());
    (rq, rs, sig)
}

// ------------------------------------------------------------------ receipts

#[test]
fn real_near_ai_gateway_ed25519_signature_verifies() {
    // GET https://cloud-api.near.ai/v1/attestation/report (2026-11-20): ohttp_attestation, signed by the gateway key
    let pk = unhex_n::<32>("40599fb284f43953bb356b09080fd803c960fc10285ad90eca462ca711ad4acb").unwrap();
    let msg = unhex("010020e4e354364111f2295e2d2ed97ce1103c9fdcb261459ec626d9bd8a6e15f0d11600080001000100010003").unwrap();
    let sig = unhex("823086655feb1660e7975d8dfdbfd728af36cc7776f69f7b5f713753306d5a8a96b1bc49298800ef36c06ccccfeed13e1fbc4b48233496af3a3a514b6d61680b").unwrap();
    let k = SignerKey { scheme: Scheme::Ed25519, kind: Kind::Gateway, key: pk.to_vec(), model: None, active: true };
    assert!(check_signature(&C, &k, &msg, &sig));
    let mut bad = msg.clone();
    bad[5] ^= 1;
    assert!(!check_signature(&C, &k, &bad, &sig));
}

#[test]
fn ed25519_receipt_roundtrip() {
    let sk = EdKey::from_bytes(&[7; 32]);
    let k = SignerKey { scheme: Scheme::Ed25519, kind: Kind::Gateway, key: sk.verifying_key().to_bytes().to_vec(), model: None, active: true };
    let base = [0xab; 20];
    let (rq, rs) = (request(DS, &base, 2, &[1; 32]), response(DS, 10, 20));
    let text = signed_text(Kind::Gateway, DS, &C.sha256(&rq), &C.sha256(&rs));
    let sig = sk.sign(text.as_bytes()).to_bytes();
    let v = verify(&C, &k, &rq, &rs, &sig).unwrap();
    assert_eq!(v.juror, Juror { runner: base, round: 2, case_hash: [1; 32] });
    assert_eq!(v.usage, Usage { prompt_tokens: 10, completion_tokens: 20 });
}

#[test]
fn ecdsa_gateway_receipt_and_tamper() {
    let s = settings();
    let base = [0xab; 20];
    let (rq, rs, sig) = signed_receipt(KIMI, &base);
    let v = verify(&C, &s.signers[0], &rq, &rs, &sig).unwrap();
    assert_eq!(v.model, KIMI);
    let mut rs2 = rs.clone();
    let i = rs2.windows(4).position(|w| w == b"3120").unwrap();
    rs2[i] = b'1'; // claim fewer tokens
    assert_eq!(verify(&C, &s.signers[0], &rq, &rs2, &sig), Err("signature"));
    let mut retired = s.signers[0].clone();
    retired.active = false;
    assert_eq!(verify(&C, &retired, &rq, &rs, &sig), Err("signer retired"));
}

#[test]
fn provider_tee_key_is_bound_to_its_model() {
    let tee = key(0x7e);
    let k = SignerKey { scheme: Scheme::Ecdsa, kind: Kind::ProviderTee, key: addr(&tee).to_vec(), model: Some(DS.into()), active: true };
    let base = [0xab; 20];
    for (model, ok) in [(DS, true), (KIMI, false)] {
        let (rq, rs) = (request(model, &base, 1, &[2; 32]), response(model, 1, 1));
        let text = signed_text(Kind::ProviderTee, model, &C.sha256(&rq), &C.sha256(&rs));
        assert!(text.starts_with(&format!("{model}:")));
        let r = verify(&C, &k, &rq, &rs, &personal_sign(&tee, text.as_bytes()));
        assert_eq!(r.is_ok(), ok, "{model}");
    }
}

#[test]
fn response_model_must_match_and_no_streams() {
    let s = settings();
    let base = [0xab; 20];
    let (rq, rs) = (request(KIMI, &base, 1, &[2; 32]), response(DS, 1, 1));
    let text = signed_text(Kind::Gateway, KIMI, &C.sha256(&rq), &C.sha256(&rs));
    assert_eq!(verify(&C, &s.signers[0], &rq, &rs, &personal_sign(&gateway(), text.as_bytes())), Err("response model"));
}

#[test]
fn juror_line_is_strict() {
    let a = "ab".repeat(20);
    let h = "cd".repeat(32);
    assert!(parse_juror(&format!("botled juror 0x{a} round 3 case 0x{h}\nrest")).is_ok());
    for bad in [
        format!("botled juror 0x{} round 3 case 0x{h}\n", a.to_uppercase()),
        format!("botled juror 0x{a} round 03 case 0x{h}\n"),
        format!("botled juror 0x{a} round 3 case 0x{h} \n"),
        format!(" botled juror 0x{a} round 3 case 0x{h}\n"),
        format!("botled juror 0x{a} round 256 case 0x{h}\n"),
        format!("botled juror {a} round 3 case 0x{h}\n"),
    ] {
        assert!(parse_juror(&bad).is_err(), "{bad}");
    }
}

#[test]
fn high_s_is_rejected() {
    let k = gateway();
    let msg = b"hello";
    let mut sig = personal_sign(&k, msg);
    assert_eq!(recover_personal(&C, msg, &sig), Some(addr(&k)));
    // flip s -> n - s and v
    let sb: [u8; 32] = sig[32..64].try_into().unwrap();
    let n = k256::Scalar::from_repr(sb.into()).unwrap();
    let flipped: [u8; 32] = (-n).to_bytes().into();
    sig[32..64].copy_from_slice(&flipped);
    sig[64] ^= 1;
    assert_eq!(recover_personal(&C, msg, &sig), None);
}
use k256::elliptic_curve::PrimeField as _;

// ------------------------------------------------------------------ pricing and billing

#[test]
fn kimi_case_costs_about_two_and_a_half_cents() {
    let s = settings();
    assert_eq!(price(&s.lanes[0], 3120, 912), 25_344); // $0.025344
    assert_eq!(price(&s.lanes[0], 1, 0), 4); // 3.3 rounded up
    assert_eq!(price(&s.lanes[0], 0, 0), 0);
}

#[test]
fn sponsor_and_byo_billing() {
    let s = settings();
    let base = [0xab; 20];
    let (rq, rs, sig) = signed_receipt(KIMI, &base);
    let v = verify(&C, &s.signers[0], &rq, &rs, &sig).unwrap();
    let mut r = runner_with(base, 10 * USDC);
    let c = charge_run(&s, &mut r, "alice.near", "relay.botled.near", &v, 0).unwrap();
    assert_eq!((c.charged, c.shortfall, c.payee.as_str()), (25_344, 0, "relay.botled.near"));
    assert_eq!(r.budget, 10 * USDC - 25_344);
    // BYO key: the runner reimburses itself from its own budget
    let c = charge_run(&s, &mut r, "alice.near", "alice.near", &v, 0).unwrap();
    assert_eq!(c.payee, "alice.near");
    // nobody else may bill
    assert_eq!(charge_run(&s, &mut r, "alice.near", "mallory.near", &v, 0), Err("not a sponsor"));
    // one billed run per seat
    assert_eq!(charge_run(&s, &mut r, "alice.near", "relay.botled.near", &v, 1), Err("seat already billed"));
    // a receipt for another runner's juror line can't drain this budget
    let mut other = runner_with([0x01; 20], USDC);
    assert_eq!(charge_run(&s, &mut other, "bob.near", "relay.botled.near", &v, 0), Err("receipt is for another runner"));
}

#[test]
fn shortfall_caps_and_unknown_models() {
    let mut s = settings();
    let base = [0xab; 20];
    let (rq, rs, sig) = signed_receipt(KIMI, &base);
    let v = verify(&C, &s.signers[0], &rq, &rs, &sig).unwrap();
    let mut r = runner_with(base, 10_000);
    let c = charge_run(&s, &mut r, "a.near", "a.near", &v, 0).unwrap();
    assert_eq!((c.cost, c.charged, c.shortfall, r.budget), (25_344, 10_000, 15_344, 0));
    s.params.max_cost_per_run = 1_000;
    let mut r = runner_with(base, USDC);
    assert_eq!(charge_run(&s, &mut r, "a.near", "a.near", &v, 0).unwrap().charged, 1_000);
    s.lanes.retain(|l| l.model != KIMI);
    assert_eq!(charge_run(&s, &mut r, "a.near", "a.near", &v, 0), Err("model is not a lane"));
}

// ------------------------------------------------------------------ signup, tickets, exit

#[test]
fn signup_splits_5_5_10_and_needs_base_proof() {
    let s = settings();
    let k = key(0x42);
    let base = addr(&k);
    let msg = signup_message("alice.near", &base, "registry.botled.near");
    assert!(msg.contains(&format!("base: 0x{}", hex(&base))));
    let sig = personal_sign(&k, msg.as_bytes());
    let (r, credits) = signup(&C, &s, "alice.near", "registry.botled.near", None, base, &sig, 20 * USDC).unwrap();
    assert_eq!(r.budget, 10 * USDC);
    assert_eq!(credits, vec![("profit.botled.near".into(), 5 * USDC), ("dev.botled.near".into(), 5 * USDC)]);
    // more than $20: surplus is budget
    let (r2, _) = signup(&C, &s, "alice.near", "registry.botled.near", None, base, &sig, 25 * USDC).unwrap();
    assert_eq!(r2.budget, 15 * USDC);
    assert_eq!(signup(&C, &s, "alice.near", "registry.botled.near", None, base, &sig, 19 * USDC).unwrap_err(), "signup fee");
    // the signature binds the NEAR account and the registry
    assert_eq!(signup(&C, &s, "bob.near", "registry.botled.near", None, base, &sig, 20 * USDC).unwrap_err(), "base proof");
    assert_eq!(signup(&C, &s, "alice.near", "other.near", None, base, &sig, 20 * USDC).unwrap_err(), "base proof");
    assert_eq!(signup(&C, &s, "alice.near", "registry.botled.near", Some(&r), base, &sig, 20 * USDC).unwrap_err(), "already registered");
}

#[test]
fn tickets_charge_each_no_show_once() {
    let s = settings();
    let mut r = runner_with([0xab; 20], 10 * USDC);
    let t = plan_ticket(&s, &mut r, 0, 1_000).unwrap();
    assert_eq!((t.epoch, t.no_shows_covered, t.penalty, t.valid_until), (1, 0, 0, 1_000 + 7 * 86_400));
    let t = plan_ticket(&s, &mut r, 2, 2_000).unwrap();
    assert_eq!((t.epoch, t.no_shows_covered, t.penalty), (2, 2, 4 * USDC));
    assert_eq!(r.budget, 6 * USDC);
    // renewing with the same count costs nothing; under-claiming never refunds
    assert_eq!(plan_ticket(&s, &mut r, 2, 3_000).unwrap().penalty, 0);
    let t = plan_ticket(&s, &mut r, 1, 3_000).unwrap();
    assert_eq!((t.no_shows_covered, t.penalty), (2, 0));
    // dry budget: no ticket -> the Base ticket expires -> no more draws
    assert_eq!(plan_ticket(&s, &mut r, 5, 4_000), Err("budget too low"));
    assert_eq!(r.no_shows_charged, 2, "failed plan changes nothing");
}

#[test]
fn enroll_digest_matches_base_pool() {
    // vector from test/near/BotledV5Near.t.sol::testEnrollDigestVector
    let d = PoolDomain { chain_id: 8453, pool: unhex_n("3381cD18e2Fb4dB236BF0525938AB6E43Db0440f").unwrap() };
    let got = enroll_digest(&C, &d, &[0x11; 20], &near_account_hash(&C, "runner.botled.near"), 7, 2, 1_800_000_000, &[0x33; 20]);
    assert_eq!(hex(&got), "d7c5202aabe0341239ada4030c90c8f5b3668447490ed2cb528f551a153aa8c1");
}

#[test]
fn sponsor_digest_matches_near_config() {
    // vector from test/near/BotledV5Near.t.sol::testSponsorDigestVector
    let cfg = unhex_n::<20>("13aa49bAc059d709dd0a18D6bb63290076a702D7").unwrap();
    let mut rq = [0u8; 32];
    rq[31] = 0xaa;
    let mut rs = [0u8; 32];
    rs[31] = 0xbb;
    let d = sponsor_digest(&C, 8453, &cfg, &[0x11; 20], 1, &[0x22; 32], &rq, &rs);
    assert_eq!(hex(&d), "1e3b46b006fbf28d5c77a961e54291be9f9bf43ace82bfdb91ea791abce704ad");
}

#[test]
fn exit_waits_for_last_ticket() {
    let s = settings();
    let mut r = runner_with([0xab; 20], 10 * USDC);
    plan_ticket(&s, &mut r, 0, 1_000).unwrap();
    let at = request_exit(&s, &mut r, 2_000).unwrap();
    assert_eq!(at, 1_000 + 7 * 86_400 + 2 * 86_400);
    assert_eq!(plan_ticket(&s, &mut r, 0, 3_000), Err("not active"));
    assert_eq!(topup(&mut r, 1), Err("topup"));
    assert_eq!(finish_exit(&mut r, at - 1), Err("exit not due"));
    assert_eq!(finish_exit(&mut r, at), Ok(10 * USDC));
    assert_eq!(r.status, Status::Exited);
}

#[test]
fn timelocked_changes() {
    let mut s = settings();
    let bad = Change::AddSigner(SignerKey { scheme: Scheme::Ed25519, kind: Kind::Gateway, key: vec![0; 20], model: None, active: true });
    assert!(validate(&bad).is_err());
    let mut p = Params::default();
    p.profit_cut = 16 * USDC;
    assert!(validate(&Change::Params(p)).is_err());
    let ch = Pending { change: Change::Sponsors(vec![]), eta: 100 };
    assert_eq!(apply(&mut s, ch.clone(), 99), Err("timelock"));
    assert_eq!(apply(&mut s, ch, 100), Ok(None));
    assert!(s.sponsors.is_empty());
    assert_eq!(apply(&mut s, Pending { change: Change::Owner("new.near".into()), eta: 0 }, 0), Ok(Some("new.near".into())));
}

// ------------------------------------------------------------------ chain signatures

#[cfg(feature = "derivation")]
#[test]
fn chain_signature_derivation_matches_v1_signer() {
    use crate::chainsig::*;
    // v1.signer.derived_public_key({predecessor:"alice.near", path:"base-1", domain_id:0}) on mainnet
    let root = parse_near_secp(MAINNET_ROOT).unwrap();
    let want = parse_near_secp(
        "secp256k1:4A7pNQBPPvvW1NZZXqSa4XJzgzmMNyvaqAzHMkNQ4rED853s3awLaVT7vMmBDq58vkUnZBjoay38x2wknvjLXAXN",
    )
    .unwrap();
    let got = derive_public_key(&root, "alice.near", "base-1").unwrap();
    assert_eq!(got, want);
    println!("alice.near/base-1 Base address: 0x{}", hex(&eth_address(&C, &got)));
}

#[test]
fn lane_key_class_is_enforced_when_billing() {
    let s = settings();
    let base = [0xab; 20];
    // a DeepSeek response signed by the gateway (not its TEE key) is not billable on the DeepSeek lane
    let (rq, rs) = (request(DS, &base, 1, &[3; 32]), response(DS, 100, 100));
    let text = signed_text(Kind::Gateway, DS, &C.sha256(&rq), &C.sha256(&rs));
    let v = verify(&C, &s.signers[0], &rq, &rs, &personal_sign(&gateway(), text.as_bytes())).unwrap();
    let mut r = runner_with(base, USDC);
    assert_eq!(charge_run(&s, &mut r, "a.near", "relay.botled.near", &v, 0), Err("wrong key class for lane"));
    // with the TEE key it is, and it is cheap: 100*0.30 + 100*1.20 per M
    let text = signed_text(Kind::ProviderTee, DS, &C.sha256(&rq), &C.sha256(&rs));
    let v = verify(&C, &s.signers[1], &rq, &rs, &personal_sign(&key(0x7e), text.as_bytes())).unwrap();
    assert_eq!(charge_run(&s, &mut r, "a.near", "relay.botled.near", &v, 0).unwrap().charged, 150);
}

/// REAL NEAR AI receipts (test/near-vectors/real, produced by runner-near/tools/fetch-real-receipt.ts).
/// Skipped (with a note) while the vector files are absent.
#[test]
fn real_near_ai_chat_receipts() {
    // Real paid NEAR AI receipts (runner-near/tools/fetch-real-receipt.ts, 2026-11-20). Keys are PINNED here, not read
    // from the vector: kimi-k3 -> NEAR AI gateway; DeepSeek-V4.1-Flash-1017 -> its own TEE keys (attestation report).
    const PINNED: [(&str, Kind, &str, &str, &str); 2] = [
        ("kimi", Kind::Gateway, KIMI, "b98a789cdc4817275f5155593ba73ef2a957e779", "40599fb284f43953bb356b09080fd803c960fc10285ad90eca462ca711ad4acb"),
        ("deepseek", Kind::ProviderTee, DS, "fe0071895500a9755c18044948ab4f4e1a7f337e", "236f5a6b91dd47dc3b7b36e43d4eb531a042ffb8f8fbf3a1555b78cef4fdda4c"),
    ];
    let dir = concat!(env!("CARGO_MANIFEST_DIR"), "/../../test/near-vectors/real/");
    for (name, kind, model, ecdsa, ed) in PINNED {
        let Ok(meta) = std::fs::read_to_string(format!("{dir}{name}.receipt.json")) else {
            println!("real receipt vector missing (skipped): {name}");
            continue;
        };
        let meta: serde_json::Value = serde_json::from_str(&meta).unwrap();
        let rq = std::fs::read(format!("{dir}{name}.request.json")).unwrap();
        let rs = std::fs::read(format!("{dir}{name}.response.json")).unwrap();
        let tee_model = (kind == Kind::ProviderTee).then(|| model.to_string());
        for (scheme, algo, pk) in [(Scheme::Ecdsa, "ecdsa", ecdsa), (Scheme::Ed25519, "ed25519", ed)] {
            let key = SignerKey { scheme, kind, key: unhex(pk).unwrap(), model: tee_model.clone(), active: true };
            let sig = unhex(meta["signatures"][algo]["signature"].as_str().unwrap()).unwrap();
            let v = verify(&C, &key, &rq, &rs, &sig).expect(name);
            assert_eq!(v.model, model);
            assert_eq!(v.kind, kind);
            assert_eq!(v.juror.runner, [0x11; 20]);
            assert_eq!(v.juror.case_hash, [0x22; 32]);
            // wrong key class / other model must fail
            let wrong = SignerKey { kind: if kind == Kind::Gateway { Kind::ProviderTee } else { Kind::Gateway }, model: Some("x".into()), ..key.clone() };
            assert!(verify(&C, &wrong, &rq, &rs, &sig).is_err());
            let cost = price(&settings().lanes.iter().find(|l| l.model == model).unwrap().clone(), v.usage.prompt_tokens, v.usage.completion_tokens);
            println!("real {name} {algo}: usage {:?}, cost {cost} uUSDC", v.usage);
        }
    }
}

// ---------------------------------------------------------------- 1Click penalty bridge
mod oneclick_tests {
    use super::*;
    use crate::oneclick::*;

    const USDC_NEAR: &str = "nep141:17208628f84f5d6ad33f0da3bbbeb27ffcb398eac501a31bd6ad2011e36133a1";
    const USDC_BASE: &str = "nep141:base-0x833589fcd6edb6e08f4c7c32d4f71b54bda02913.omft.near";
    const SWAPPER: &str = "0x13aa49bAc059d709dd0a18D6bb63290076a702D7";
    const DEPOSIT: &str = "f3fce586c1a5f39db509a667205360ce8b9cd0e09df86041256a9594c98bc0d2";
    const NOW: u64 = 1_795_000_000; // 2026-11-18

    fn mk() -> EdKey {
        EdKey::from_bytes(&[9u8; 32])
    }
    fn bridge() -> RewardBridge {
        RewardBridge {
            manager_key: bs58::encode(mk().verifying_key().to_bytes()).into_string(),
            origin_asset: USDC_NEAR.into(),
            destination_asset: USDC_BASE.into(),
            recipient: SWAPPER.to_lowercase(),
            max_slippage_bps: 100,
            min_amount: 10_000_000,
        }
    }
    fn payload(amount: u128, min_out: u128, f: impl Fn(&mut serde_json::Value)) -> String {
        let mut v = serde_json::json!({
            "amount": amount.to_string(), "amountIn": amount.to_string(), "amountOut": (amount * 9997 / 10000).to_string(),
            "deadline": "2026-11-21T12:00:00.000Z", "depositAddress": DEPOSIT, "depositType": "ORIGIN_CHAIN",
            "destinationAsset": USDC_BASE, "dry": false, "minAmountOut": min_out.to_string(), "originAsset": USDC_NEAR,
            "recipient": SWAPPER, "recipientType": "DESTINATION_CHAIN", "refundTo": "rewards.botled.near",
            "refundType": "ORIGIN_CHAIN", "slippageTolerance": 100, "swapType": "EXACT_INPUT"
        });
        f(&mut v);
        v.to_string()
    }
    fn sign(p: &str) -> String {
        let msg = bs58::encode(sha2::Sha256::digest(p.as_bytes())).into_string();
        format!("ed25519:{}", bs58::encode(mk().sign(msg.as_bytes()).to_bytes()).into_string())
    }
    fn go(p: &str) -> Result<Bound, &'static str> {
        bind(&C, &bridge(), p, &sign(p), "rewards.botled.near", 50_000_000, NOW)
    }

    #[test]
    fn bound_quote_moves_exact_amount_to_its_deposit_address() {
        let p = payload(20_000_000, 19_800_000, |_| {});
        let b = go(&p).unwrap();
        assert_eq!((b.deposit_address.as_str(), b.amount_in, b.min_amount_out), (DEPOSIT, 20_000_000, 19_800_000));
        assert_eq!(crate::oneclick::validate(&bridge()), Ok(()));
    }

    #[test]
    fn keeper_cannot_redirect_resize_or_reprice() {
        let cases: Vec<(Box<dyn Fn(&mut serde_json::Value)>, &str)> = vec![
            (Box::new(|v| v["recipient"] = "0x000000000000000000000000000000000000beef".into()), "recipient mismatch"),
            (Box::new(|v| v["refundTo"] = "keeper.near".into()), "refund target"),
            (Box::new(|v| v["destinationAsset"] = "nep141:eth-0xa0b8.omft.near".into()), "quote assets"),
            (Box::new(|v| v["originAsset"] = "nep141:wrap.near".into()), "quote assets"),
            (Box::new(|v| v["dry"] = true.into()), "dry quote"),
            (Box::new(|v| v["swapType"] = "EXACT_OUTPUT".into()), "quote type"),
            (Box::new(|v| v["recipientType"] = "INTENTS".into()), "quote type"),
            (Box::new(|v| v["minAmountOut"] = "19700000".into()), "slippage above cap"), // 1.5% > 1%
            (Box::new(|v| { v["amountIn"] = "60000000".into(); v["amount"] = "60000000".into(); }), "quote amount out of bounds"),
            (Box::new(|v| { v["amountIn"] = "5000000".into(); v["amount"] = "5000000".into(); v["minAmountOut"] = "4990000".into(); }), "quote amount out of bounds"),
            (Box::new(|v| v["amount"] = "1".into()), "amount mismatch"),
            (Box::new(|v| v["deadline"] = "2026-11-18T07:00:00.000Z".into()), "quote expired"),
            (Box::new(|v| v["depositAddress"] = "Bad..Account".into()), "deposit address"),
        ];
        for (f, want) in cases {
            let p = payload(20_000_000, 19_800_000, &f);
            assert_eq!(go(&p).unwrap_err(), want, "{p}");
        }
        // a field changed after signing breaks the 1Click signature
        let p = payload(20_000_000, 19_800_000, |_| {});
        let s = sign(&p);
        let p2 = p.replace(DEPOSIT, &"a".repeat(64));
        assert_eq!(bind(&C, &bridge(), &p2, &s, "rewards.botled.near", 50_000_000, NOW).unwrap_err(), "bad quote signature");
    }

    #[test]
    fn real_one_click_signature_verifies_with_pinned_key() {
        // live 1Click quote (near-hire fixture, wNEAR -> Base USDC): proves the signature scheme + pinned key; the
        // binding then rejects it because it is not a USDC -> swapper quote
        let f: serde_json::Value = serde_json::from_str(include_str!("../testdata/oneclick-live-quote.json")).unwrap();
        let (p, s) = (f["payload"].as_str().unwrap(), f["signature"].as_str().unwrap());
        let mut b = bridge();
        b.manager_key = ONE_CLICK_MANAGER_KEY.into();
        assert_eq!(bind(&C, &b, p, s, "example.near", u128::MAX, NOW).unwrap_err(), "quote assets");
        assert_eq!(bind(&C, &b, &p.replace("example.near", "x.near"), s, "x.near", u128::MAX, NOW).unwrap_err(), "bad quote signature");
    }

    #[test]
    fn iso_deadlines() {
        assert_eq!(iso_secs("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(iso_secs("2026-11-21T12:00:00.000Z"), Some(1_795_262_400));
        assert_eq!(iso_secs("2024-02-29T23:59:59.999Z"), Some(1_709_251_199));
        assert_eq!(iso_secs("2026-13-01T00:00:00Z"), None);
        assert_eq!(iso_secs("2026-11-21 12:00:00Z"), None);
    }

    #[test]
    fn bridge_config_is_bounded() {
        let mut b = bridge();
        b.max_slippage_bps = 301;
        assert_eq!(crate::oneclick::validate(&b), Err("bridge"));
        let mut b = bridge();
        b.recipient = "0x1234".into();
        assert_eq!(crate::oneclick::validate(&b), Err("bridge"));
    }
}
