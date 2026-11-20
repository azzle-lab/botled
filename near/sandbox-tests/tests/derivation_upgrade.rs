//! Local neard sandbox only. (1) Code upgrade of the deployed mainnet wasm (sha256 83d2684e…, kept at
//! near/target/botled_registry.v1-83d2.wasm) to the `derivation` build: state, settings and pending changes survive.
//! (2) Signup gas with chain-signature derivation; a wrong Base address is refused.
use botled_logic::crypto::{hex, personal_hash, Crypto};
use botled_logic::receipt::{Kind, Scheme, SignerKey};
use botled_logic::registry::{LanePrice, Params, Settings};
use k256::ecdsa::SigningKey;
use k256::elliptic_curve::PrimeField;
use k256::{NonZeroScalar, Scalar};
use near_workspaces::types::NearToken;
use serde_json::{json, Value};
use sha2::Digest as _;

struct Native;
impl Crypto for Native {
    fn sha256(&self, d: &[u8]) -> [u8; 32] { sha2::Sha256::digest(d).into() }
    fn keccak256(&self, d: &[u8]) -> [u8; 32] { sha3::Keccak256::digest(d).into() }
    fn ed25519_verify(&self, _: &[u8; 64], _: &[u8], _: &[u8; 32]) -> bool { unimplemented!() }
    fn ecrecover(&self, _: &[u8; 32], _: &[u8; 64], _: u8) -> Option<[u8; 64]> { unimplemented!() }
}
const C: Native = Native;

fn pk64(k: &SigningKey) -> [u8; 64] { k.verifying_key().to_encoded_point(false).as_bytes()[1..].try_into().unwrap() }
fn addr(k: &SigningKey) -> [u8; 20] { C.keccak256(&pk64(k))[12..].try_into().unwrap() }
fn psign(k: &SigningKey, msg: &[u8]) -> String {
    let (sig, rec) = k.sign_prehash_recoverable(&personal_hash(&C, msg)).unwrap();
    let mut out = sig.to_bytes().to_vec();
    out.push(27 + rec.to_byte());
    hex(&out)
}
fn root_secret() -> Scalar { Scalar::from_repr([0x42; 32].into()).unwrap() }
fn child(account: &str) -> SigningKey {
    let e = botled_logic::chainsig::epsilon(account, "base-1").unwrap();
    SigningKey::from(NonZeroScalar::new(root_secret() + e).unwrap())
}

#[tokio::test]
async fn upgrade_keeps_state_and_enforces_derivation() -> anyhow::Result<()> {
    let dir = concat!(env!("CARGO_MANIFEST_DIR"), "/../target");
    let old = std::fs::read(format!("{dir}/botled_registry.v1-83d2.wasm"))?;
    let new = std::fs::read(format!("{dir}/near/botled_registry/botled_registry.wasm"))?;
    let worker = near_workspaces::sandbox().await?;
    let root = worker.root_account()?;
    let mk = |name: &'static str| {
        let root = root.clone();
        async move { root.create_subaccount(name).initial_balance(NearToken::from_near(20)).transact().await.map(|r| r.into_result().unwrap()) }
    };
    let registry = mk("registry").await?;
    let usdc = mk("usdc").await?;
    let alice = mk("alice").await?;
    let bob = mk("bob").await?;
    let settings = serde_json::to_value(Settings {
        params: Params::default(),
        usdc: usdc.id().to_string(),
        profit_to: root.id().to_string(),
        dev_to: root.id().to_string(),
        penalty_to: root.id().to_string(),
        lanes: vec![LanePrice { model: "moonshotai/kimi-k3".into(), input_per_mtok: 3_300_000, output_per_mtok: 16_500_000, receipt_kind: Kind::Gateway }],
        signers: vec![SignerKey { scheme: Scheme::Ecdsa, kind: Kind::Gateway, key: vec![0xb9; 20], model: None, active: true }],
        sponsors: vec![],
        pool: botled_logic::ticket::PoolDomain { chain_id: 8453, pool: [0; 20] },
        reward_bridge: None,
    })?;
    let root_pk = pk64(&SigningKey::from(NonZeroScalar::new(root_secret()).unwrap()));
    // v1 (mainnet code), same init shape as mainnet (mpc_root stored)
    let c = registry.deploy(&old).await?.into_result()?;
    c.call("new").args_json(json!({"owner": registry.id(), "timelock_secs": 86400, "mpc": "v1.signer", "settings": settings, "mpc_root": hex(&root_pk)}))
        .max_gas().transact().await?.into_result()?;
    // v1: signup with an arbitrary key is accepted (no derivation) -> bob binds a non-MPC base
    let k = SigningKey::from_bytes(&[7u8; 32].into()).unwrap();
    let msg: String = c.view("signup_message").args_json(json!({"account": bob.id(), "base": hex(&addr(&k))})).await?.json()?;
    usdc.call(c.id(), "ft_on_transfer").args_json(json!({"sender_id": bob.id(), "amount": "20000000",
        "msg": json!({"signup": {"base": format!("0x{}", hex(&addr(&k))), "sig": psign(&k, msg.as_bytes())}}).to_string()}))
        .max_gas().transact().await?.into_result()?;
    for change in [json!({"Recipients": {"profit_to": "azzle.near", "dev_to": "azzle.near", "penalty_to": root.id()}}), json!({"Pool": {"chain_id": 8453, "pool": vec![0x4fu8; 20]}})] {
        registry.call(c.id(), "propose").args_json(json!({"change": change})).max_gas().transact().await?.into_result()?;
    }
    let pending_before: Value = c.view("get_pending").await?.json()?;
    let settings_before: Value = c.view("get_settings").await?.json()?;
    let bob_before: Value = c.view("get_runner").args_json(json!({"account": bob.id()})).await?.json()?;

    // plain DeployContract (no init) = what mainnet gets
    registry.deploy(&new).await?.into_result()?;
    let pending_after: Value = c.view("get_pending").await?.json()?;
    let settings_after: Value = c.view("get_settings").await?.json()?;
    assert_eq!(pending_before, pending_after, "pending changes survive");
    assert_eq!(pending_after.as_array().unwrap().len(), 2);
    assert_eq!(settings_before, settings_after, "settings survive");
    assert_eq!(bob_before, c.view("get_runner").args_json(json!({"account": bob.id()})).await?.json::<Value>()?, "runners survive");

    // derivation now enforced
    let want: Option<String> = c.view("chain_signature_base").args_json(json!({"account": alice.id()})).await?.json()?;
    let ak = child(alice.id().as_str());
    assert_eq!(want, Some(format!("0x{}", hex(&addr(&ak)))));
    let wrong = SigningKey::from_bytes(&[9u8; 32].into()).unwrap();
    let msg: String = c.view("signup_message").args_json(json!({"account": alice.id(), "base": hex(&addr(&wrong))})).await?.json()?;
    let r = usdc.call(c.id(), "ft_on_transfer").args_json(json!({"sender_id": alice.id(), "amount": "20000000",
        "msg": json!({"signup": {"base": format!("0x{}", hex(&addr(&wrong))), "sig": psign(&wrong, msg.as_bytes())}}).to_string()}))
        .max_gas().transact().await?;
    assert!(r.is_failure(), "wrong base refused");
    assert!(format!("{:?}", r.into_result().unwrap_err()).contains("chain-signature address"));
    let msg: String = c.view("signup_message").args_json(json!({"account": alice.id(), "base": hex(&addr(&ak))})).await?.json()?;
    let r = usdc.call(c.id(), "ft_on_transfer").args_json(json!({"sender_id": alice.id(), "amount": "20000000",
        "msg": json!({"signup": {"base": format!("0x{}", hex(&addr(&ak))), "sig": psign(&ak, msg.as_bytes())}}).to_string()}))
        .max_gas().transact().await?;
    println!("gas signup with derivation: {:.2} Tgas", r.total_gas_burnt.as_gas() as f64 / 1e12);
    r.into_result()?;
    let g = c.view("chain_signature_base").args_json(json!({"account": alice.id()})).await?;
    println!("view chain_signature_base ok ({} bytes result)", g.result.len());
    Ok(())
}
