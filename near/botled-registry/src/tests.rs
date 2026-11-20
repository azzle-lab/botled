use super::*;
use botled_logic::crypto::{eth_address, personal_hash};
use botled_logic::receipt::{signed_text, Kind, Scheme};
use botled_logic::registry::{LanePrice, Params, USDC};
use botled_logic::ticket::PoolDomain;
use k256::ecdsa::SigningKey;
use near_sdk::test_utils::VMContextBuilder;
use near_sdk::testing_env;

const KIMI: &str = "moonshotai/kimi-k3";
const DAY: u64 = 86_400;

fn acc(s: &str) -> AccountId {
    s.parse().unwrap()
}

fn key(n: u8) -> SigningKey {
    SigningKey::from_bytes(&[n; 32].into()).unwrap()
}

fn addr(k: &SigningKey) -> [u8; 20] {
    let pk: [u8; 64] = k.verifying_key().to_encoded_point(false).as_bytes()[1..].try_into().unwrap();
    eth_address(&C, &pk)
}

fn psign(k: &SigningKey, msg: &[u8]) -> String {
    let (sig, rec) = k.sign_prehash_recoverable(&personal_hash(&C, msg)).unwrap();
    let mut out = sig.to_bytes().to_vec();
    out.push(27 + rec.to_byte());
    hex(&out)
}

fn ctx(pred: &str, t: u64, deposit: u128) {
    testing_env!(VMContextBuilder::new()
        .current_account_id(acc("registry.botled.near"))
        .predecessor_account_id(acc(pred))
        .block_timestamp(t * 1_000_000_000)
        .attached_deposit(NearToken::from_yoctonear(deposit))
        .build());
}

fn settings() -> Settings {
    Settings {
        params: Params::default(),
        usdc: "usdc.near".into(),
        profit_to: "profit.botled.near".into(),
        dev_to: "dev.botled.near".into(),
        penalty_to: "rewards.botled.near".into(),
        lanes: vec![LanePrice { model: KIMI.into(), input_per_mtok: 3_300_000, output_per_mtok: 16_500_000, receipt_kind: Kind::Gateway }],
        signers: vec![SignerKey { scheme: Scheme::Ecdsa, kind: Kind::Gateway, key: addr(&key(0x6a)).to_vec(), model: None, active: true }],
        sponsors: vec!["relay.botled.near".into()],
        pool: PoolDomain { chain_id: 8453, pool: [0x33; 20] },
        reward_bridge: None,
    }
}

fn setup() -> Contract {
    ctx("owner.near", 1_000, 0);
    Contract::new(acc("owner.near"), DAY, acc("v1.signer"), settings(), None)
}

fn signup(c: &mut Contract, who: &str, k: &SigningKey, amount: u128) {
    let base = addr(k);
    ctx(who, 1_000, 0);
    let sig = psign(k, c.signup_message(acc(who), hex(&base)).as_bytes());
    ctx("usdc.near", 1_000, 0);
    let msg = json!({"signup": {"base": format!("0x{}", hex(&base)), "sig": sig}}).to_string();
    let _ = c.ft_on_transfer(acc(who), U128(amount), msg);
}

fn receipt(base: &[u8; 20], round: u8, case: u8, pt: u64, ct: u64) -> (Base64VecU8, Base64VecU8, String) {
    let user = format!("botled juror 0x{} round {round} case 0x{}\n<task_scope>…", hex(base), hex(&[case; 32]));
    let rq = format!(
        r#"{{"model":"{KIMI}","messages":[{{"role":"system","content":"x"}},{{"role":"user","content":{}}}],"stream":false}}"#,
        serde_json::to_string(&user).unwrap()
    );
    let rs = format!(
        r#"{{"model":"{KIMI}","choices":[{{"message":{{"content":"{{}}"}}}}],"usage":{{"prompt_tokens":{pt},"completion_tokens":{ct}}}}}"#
    );
    let text = signed_text(Kind::Gateway, KIMI, &C.sha256(rq.as_bytes()), &C.sha256(rs.as_bytes()));
    (Base64VecU8(rq.into_bytes()), Base64VecU8(rs.into_bytes()), psign(&key(0x6a), text.as_bytes()))
}

#[test]
fn signup_splits_and_binds_base() {
    let mut c = setup();
    let k = key(1);
    signup(&mut c, "alice.near", &k, 20 * USDC);
    let r = c.get_runner(acc("alice.near")).unwrap();
    assert_eq!(r.budget.0, 10 * USDC);
    assert_eq!(r.base, format!("0x{}", hex(&addr(&k))));
    assert_eq!(c.owed_to(acc("profit.botled.near")).0, 5 * USDC);
    assert_eq!(c.owed_to(acc("dev.botled.near")).0, 5 * USDC);
    assert_eq!(c.runner_of(hex(&addr(&k))), Some(acc("alice.near")));
    // top-up by anyone for alice
    ctx("usdc.near", 1_000, 0);
    let _ = c.ft_on_transfer(acc("sponsor.near"), U128(3 * USDC), r#"{"topup":{"runner":"alice.near"}}"#.into());
    assert_eq!(c.get_runner(acc("alice.near")).unwrap().budget.0, 13 * USDC);
}

#[test]
#[should_panic(expected = "only USDC")]
fn other_tokens_are_refunded() {
    let mut c = setup();
    ctx("fake-usdc.near", 1_000, 0);
    let _ = c.ft_on_transfer(acc("alice.near"), U128(20 * USDC), r#"{"topup":{}}"#.into());
}

#[test]
#[should_panic(expected = "base address is bound")]
fn one_base_address_per_near_account() {
    let mut c = setup();
    let k = key(1);
    signup(&mut c, "alice.near", &k, 20 * USDC);
    signup(&mut c, "bob.near", &k, 20 * USDC);
}

#[test]
fn sponsor_bills_receipt_once() {
    let mut c = setup();
    let k = key(1);
    signup(&mut c, "alice.near", &k, 20 * USDC);
    let (rq, rs, sig) = receipt(&addr(&k), 1, 0xcc, 3120, 912);
    ctx("relay.botled.near", 2_000, 0);
    let out = c.record_run(rq, rs, 0, sig);
    assert_eq!((out.runner, out.charged.0), (acc("alice.near"), 25_344));
    assert_eq!(c.owed_to(acc("relay.botled.near")).0, 25_344);
    assert_eq!(c.get_runner(acc("alice.near")).unwrap().budget.0, 10 * USDC - 25_344);
}

#[test]
#[should_panic(expected = "receipt already billed")]
fn duplicate_receipt_panics() {
    let mut c = setup();
    let k = key(1);
    signup(&mut c, "alice.near", &k, 20 * USDC);
    let (rq, rs, sig) = receipt(&addr(&k), 1, 0xcc, 10, 10);
    ctx("relay.botled.near", 2_000, 0);
    c.record_run(rq.clone(), rs.clone(), 0, sig.clone());
    c.record_run(rq, rs, 0, sig);
}

#[test]
#[should_panic(expected = "seat already billed")]
fn resampling_a_seat_is_not_billed() {
    let mut c = setup();
    let k = key(1);
    signup(&mut c, "alice.near", &k, 20 * USDC);
    ctx("relay.botled.near", 2_000, 0);
    let (rq, rs, sig) = receipt(&addr(&k), 1, 0xcc, 10, 10);
    c.record_run(rq, rs, 0, sig);
    let (rq, rs, sig) = receipt(&addr(&k), 1, 0xcc, 10, 11); // a second sample for the same juror seat
    c.record_run(rq, rs, 0, sig);
}

#[test]
#[should_panic(expected = "not a sponsor")]
fn strangers_cannot_bill() {
    let mut c = setup();
    let k = key(1);
    signup(&mut c, "alice.near", &k, 20 * USDC);
    let (rq, rs, sig) = receipt(&addr(&k), 1, 0xcc, 10, 10);
    ctx("mallory.near", 2_000, 0);
    c.record_run(rq, rs, 0, sig);
}

#[test]
fn ticket_charges_no_shows_then_calls_mpc() {
    let mut c = setup();
    let k = key(1);
    signup(&mut c, "alice.near", &k, 20 * USDC);
    ctx("alice.near", 5_000, 1);
    let _ = c.request_ticket(2, "0x3333333333333333333333333333333333333333".into());
    let r = c.get_runner(acc("alice.near")).unwrap();
    assert_eq!((r.epoch, r.no_shows_charged, r.penalties.0, r.budget.0), (1, 2, 4 * USDC, 6 * USDC));
    assert_eq!(r.ticket_until, 5_000 + 7 * DAY);
    assert_eq!(c.owed_to(acc("rewards.botled.near")).0, 4 * USDC, "no-show penalties go to the reward fund");
    let out = c.on_ticket("aa".into(), "bb".into(), 1, 2, 99, "33".into(), "cc".into(), Ok(json!({"big_r": "..", "s": "..", "recovery_id": 0})));
    assert_eq!(out["noShowsCovered"], 2);
}

#[test]
#[should_panic(expected = "attach the MPC fee")]
fn ticket_needs_fee() {
    let mut c = setup();
    signup(&mut c, "alice.near", &key(1), 20 * USDC);
    ctx("alice.near", 5_000, 0);
    let _ = c.request_ticket(0, "0x3333333333333333333333333333333333333333".into());
}

#[test]
fn exit_refunds_after_last_ticket_and_delay() {
    let mut c = setup();
    signup(&mut c, "alice.near", &key(1), 20 * USDC);
    ctx("alice.near", 5_000, 1);
    let _ = c.request_ticket(0, "0x3333333333333333333333333333333333333333".into());
    let at = c.request_exit();
    assert_eq!(at, 5_000 + 7 * DAY + 2 * DAY);
    ctx("anyone.near", at, 0);
    assert_eq!(c.finish_exit(acc("alice.near")).0, 10 * USDC);
    assert_eq!(c.owed_to(acc("alice.near")).0, 10 * USDC);
    let _ = c.collect(acc("alice.near"));
    assert_eq!(c.owed_to(acc("alice.near")).0, 0);
    // a failed ft_transfer restores the claim
    c.on_collect(acc("alice.near"), U128(10 * USDC), Err(PromiseError::Failed));
    assert_eq!(c.owed_to(acc("alice.near")).0, 10 * USDC);
}

#[test]
fn owner_changes_wait_for_timelock() {
    let mut c = setup();
    ctx("owner.near", 1_000, 0);
    let id = c.propose(Change::Sponsors(vec!["relay2.botled.near".into()]));
    ctx("anyone.near", 1_000 + DAY - 1, 0);
    let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| c.apply(id)));
    assert!(r.is_err());
    ctx("anyone.near", 1_000 + DAY, 0);
    let mut c = setup();
    ctx("owner.near", 1_000, 0);
    let id = c.propose(Change::Sponsors(vec!["relay2.botled.near".into()]));
    ctx("anyone.near", 1_000 + DAY, 0);
    c.apply(id);
    assert_eq!(c.get_settings().sponsors, vec!["relay2.botled.near".to_string()]);
}

#[test]
#[should_panic(expected = "owner only")]
fn only_owner_proposes() {
    let mut c = setup();
    ctx("mallory.near", 1_000, 0);
    c.propose(Change::Sponsors(vec!["mallory.near".into()]));
}

#[test]
#[should_panic(expected = "signer retired")]
fn retired_gateway_key_stops_billing() {
    let mut c = setup();
    let k = key(1);
    signup(&mut c, "alice.near", &k, 20 * USDC);
    ctx("owner.near", 1_000, 0);
    c.retire_signer(0);
    let (rq, rs, sig) = receipt(&addr(&k), 1, 0xcc, 10, 10);
    ctx("relay.botled.near", 2_000, 0);
    c.record_run(rq, rs, 0, sig);
}

#[test]
fn billed_runs_are_listed_for_audit() {
    let mut c = setup();
    let k = key(1);
    signup(&mut c, "alice.near", &k, 20 * USDC);
    for case in 1..=3u8 {
        let (rq, rs, sig) = receipt(&addr(&k), 1, case, 3120, 912);
        ctx("relay.botled.near", 2_000 + case as u64, 0);
        c.record_run(rq, rs, 0, sig);
    }
    // BYO run by the runner itself: not sponsored
    let (rq, rs, sig) = receipt(&addr(&k), 1, 9, 100, 10);
    ctx("alice.near", 3_000, 0);
    c.record_run(rq, rs, 0, sig);
    assert_eq!(c.run_count(), 4);
    let all = c.get_runs(0, 10);
    assert_eq!(all.len(), 4);
    assert_eq!(all[0].runner, format!("0x{}", hex(&addr(&k))));
    assert_eq!(all[0].case, format!("0x{}", hex(&[1u8; 32])));
    assert_eq!((all[0].round, all[0].signer_id, all[0].at), (1, 0, 2_001));
    assert!(all[..3].iter().all(|r| r.sponsored && r.caller.as_str() == "relay.botled.near"));
    assert!(!all[3].sponsored);
    assert_eq!(all[3].account.as_str(), "alice.near");
    let page = c.get_runs(1, 2);
    assert_eq!(page.iter().map(|r| r.index).collect::<Vec<_>>(), vec![1, 2]);
    assert!(c.get_runs(4, 10).is_empty());
}

#[test]
fn penalties_bridge_only_through_a_bound_quote() {
    use botled_logic::oneclick::RewardBridge;
    use ed25519_dalek::{Signer, SigningKey as EdKey};
    use sha2::Digest;
    let mk = EdKey::from_bytes(&[9u8; 32]);
    let mut s = settings();
    s.reward_bridge = Some(RewardBridge {
        manager_key: bs58::encode(mk.verifying_key().to_bytes()).into_string(),
        origin_asset: "nep141:usdc.near".into(),
        destination_asset: "nep141:base-0x833589fcd6edb6e08f4c7c32d4f71b54bda02913.omft.near".into(),
        recipient: "0x13aa49bac059d709dd0a18d6bb63290076a702d7".into(),
        max_slippage_bps: 100,
        min_amount: 10 * USDC,
    });
    ctx("owner.near", 1_000, 0);
    let mut c = Contract::new(acc("owner.near"), DAY, acc("v1.signer"), s, None);
    c.credit(&acc("rewards.botled.near"), 30 * USDC); // = 15 no-shows charged by request_ticket
    let p = json!({
        "amount": "20000000", "amountIn": "20000000", "deadline": "2030-01-01T00:00:00.000Z",
        "depositAddress": "f3fce586c1a5f39db509a667205360ce8b9cd0e09df86041256a9594c98bc0d2", "depositType": "ORIGIN_CHAIN",
        "destinationAsset": "nep141:base-0x833589fcd6edb6e08f4c7c32d4f71b54bda02913.omft.near", "dry": false,
        "minAmountOut": "19850000", "originAsset": "nep141:usdc.near", "recipient": "0x13aa49bAc059d709dd0a18D6bb63290076a702D7",
        "recipientType": "DESTINATION_CHAIN", "refundTo": "rewards.botled.near", "refundType": "ORIGIN_CHAIN", "swapType": "EXACT_INPUT"
    })
    .to_string();
    let msg = bs58::encode(sha2::Sha256::digest(p.as_bytes())).into_string();
    let sig = format!("ed25519:{}", bs58::encode(mk.sign(msg.as_bytes()).to_bytes()).into_string());
    ctx("any-keeper.near", 2_000, 0);
    let _ = c.bridge_penalties(p.clone(), sig.clone());
    assert_eq!(c.owed_to(acc("rewards.botled.near")).0, 10 * USDC);
    let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let _ = c.bridge_penalties(p.clone(), sig.clone());
    }));
    assert!(r.is_err(), "replayed quote must panic");
    // a failed ft_transfer is re-credited by the callback (same path as collect)
    c.credit(&acc("rewards.botled.near"), 20 * USDC);
    assert_eq!(c.owed_to(acc("rewards.botled.near")).0, 30 * USDC);
}

// ------------------------------------------------------------------ chain-signature derivation (feature `derivation`)

#[cfg(feature = "derivation")]
mod derivation {
    use super::*;
    use k256::elliptic_curve::PrimeField;
    use k256::{NonZeroScalar, Scalar};

    /// test MPC root: root secret r, child secret = r + epsilon(account, "base-1") (what v1.signer does)
    fn root_secret() -> Scalar {
        Scalar::from_repr([0x42; 32].into()).unwrap()
    }

    fn root_hex() -> String {
        hex(&addr_pk(&SigningKey::from(NonZeroScalar::new(root_secret()).unwrap())))
    }

    fn addr_pk(k: &SigningKey) -> [u8; 64] {
        k.verifying_key().to_encoded_point(false).as_bytes()[1..].try_into().unwrap()
    }

    fn child(account: &str) -> SigningKey {
        let e = botled_logic::chainsig::epsilon(account, BASE_PATH).unwrap();
        SigningKey::from(NonZeroScalar::new(root_secret() + e).unwrap())
    }

    fn setup_root() -> Contract {
        ctx("owner.near", 1_000, 0);
        Contract::new(acc("owner.near"), DAY, acc("v1.signer"), settings(), Some(root_hex()))
    }

    #[test]
    fn signup_accepts_the_chain_signature_address() {
        let mut c = setup_root();
        let k = child("alice.near");
        assert_eq!(c.chain_signature_base(acc("alice.near")), Some(format!("0x{}", hex(&addr(&k)))));
        signup(&mut c, "alice.near", &k, 20 * USDC);
        assert_eq!(c.get_runner(acc("alice.near")).unwrap().base, format!("0x{}", hex(&addr(&k))));
    }

    #[test]
    #[should_panic(expected = "base is not the runner's chain-signature address")]
    fn signup_rejects_any_other_base() {
        let mut c = setup_root();
        signup(&mut c, "alice.near", &key(1), 20 * USDC); // valid EIP-191 sig, but not alice's MPC address
    }

    #[test]
    #[should_panic(expected = "base is not the runner's chain-signature address")]
    fn signup_rejects_another_accounts_mpc_address() {
        let mut c = setup_root();
        signup(&mut c, "alice.near", &child("bob.near"), 20 * USDC);
    }

    #[test]
    fn real_mainnet_root_matches_runner_near_and_v1_signer() {
        // deployed registry stores this root (= v1.signer.public_key domain 0, checked live 2026-11-20)
        let root = botled_logic::chainsig::parse_near_secp(botled_logic::chainsig::MAINNET_ROOT).unwrap();
        ctx("owner.near", 1_000, 0);
        let c = Contract::new(acc("owner.near"), DAY, acc("v1.signer"), settings(), Some(hex(&root)));
        // == runner-near chainsig.ts deriveBaseAddress == v1.signer.derived_public_key (mainnet, 2026-11-20)
        assert_eq!(c.chain_signature_base(acc("azzle.near")).unwrap(), "0xae52c39e872fc4c647f65fe724cf4391bad248fe");
        let pk = botled_logic::chainsig::derive_public_key(
            &root,
            "b0c3f8cbde21c8814baccfd84afce62f70ab33b57fe3717b01828ee41f06c625",
            botled_logic::ticket::ENROLL_PATH,
        )
        .unwrap();
        assert_eq!(hex(&eth_address(&C, &pk)), "7dd9b26e03e355d2c59e972a355c9303b8d1dd94"); // BotledNearConfig.enrollSigner
    }

    #[test]
    fn no_root_means_not_enforced() {
        let mut c = setup();
        assert_eq!(c.chain_signature_base(acc("alice.near")), None);
        signup(&mut c, "alice.near", &key(1), 20 * USDC);
    }
}
