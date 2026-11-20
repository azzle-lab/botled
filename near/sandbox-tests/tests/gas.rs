//! Gas of botled-registry on a local neard sandbox (near-workspaces). Nothing touches testnet/mainnet.
//! Build the wasm first: `cd botled-registry && cargo near build non-reproducible-wasm --no-abi`.
use botled_logic::crypto::{hex, personal_hash, Crypto};
use botled_logic::receipt::{signed_text, Kind};
use k256::ecdsa::SigningKey;
use near_workspaces::types::NearToken;
use serde_json::json;
use sha2::Digest as _;

struct Native;
impl Crypto for Native {
    fn sha256(&self, d: &[u8]) -> [u8; 32] {
        sha2::Sha256::digest(d).into()
    }
    fn keccak256(&self, d: &[u8]) -> [u8; 32] {
        sha3::Keccak256::digest(d).into()
    }
    fn ed25519_verify(&self, _: &[u8; 64], _: &[u8], _: &[u8; 32]) -> bool {
        unimplemented!()
    }
    fn ecrecover(&self, _: &[u8; 32], _: &[u8; 64], _: u8) -> Option<[u8; 64]> {
        unimplemented!()
    }
}
const C: Native = Native;
const KIMI: &str = "moonshotai/kimi-k3";
const DS: &str = "deepseek-ai/DeepSeek-V4.1-Flash-1017";

fn key(n: u8) -> SigningKey {
    SigningKey::from_bytes(&[n; 32].into()).unwrap()
}
fn addr(k: &SigningKey) -> [u8; 20] {
    let pk = k.verifying_key().to_encoded_point(false);
    let h = C.keccak256(&pk.as_bytes()[1..]);
    h[12..].try_into().unwrap()
}
fn psign(k: &SigningKey, msg: &[u8]) -> String {
    let (sig, rec) = k.sign_prehash_recoverable(&personal_hash(&C, msg)).unwrap();
    let mut out = sig.to_bytes().to_vec();
    out.push(27 + rec.to_byte());
    hex(&out)
}

#[tokio::test]
async fn registry_gas() -> anyhow::Result<()> {
    let wasm = std::fs::read(concat!(env!("CARGO_MANIFEST_DIR"), "/../target/near/botled_registry/botled_registry.wasm"))?;
    let worker = near_workspaces::sandbox().await?;
    let root = worker.root_account()?;
    let mk = |name: &'static str| {
        let root = root.clone();
        async move { root.create_subaccount(name).initial_balance(NearToken::from_near(20)).transact().await.map(|r| r.into_result().unwrap()) }
    };
    let registry = mk("registry").await?;
    let usdc = mk("usdc").await?; // plain account standing in for the USDC token (calls ft_on_transfer itself)
    let relay = mk("relay").await?;
    let alice = mk("alice").await?;
    let contract = registry.deploy(&wasm).await?.into_result()?;
    let gw = key(0x6a);
    let tee = key(0x7e);
    use botled_logic::receipt::{Scheme, SignerKey};
    use botled_logic::registry::{LanePrice, Params, Settings};
    let settings = serde_json::to_value(Settings {
        params: Params::default(),
        usdc: usdc.id().to_string(),
        profit_to: root.id().to_string(),
        dev_to: root.id().to_string(),
        penalty_to: root.id().to_string(), // reward fund stand-in
        lanes: vec![
            LanePrice { model: KIMI.into(), input_per_mtok: 3_300_000, output_per_mtok: 16_500_000, receipt_kind: Kind::Gateway },
            LanePrice { model: DS.into(), input_per_mtok: 300_000, output_per_mtok: 1_200_000, receipt_kind: Kind::ProviderTee },
        ],
        signers: vec![
            SignerKey { scheme: Scheme::Ecdsa, kind: Kind::Gateway, key: addr(&gw).to_vec(), model: None, active: true },
            SignerKey { scheme: Scheme::Ecdsa, kind: Kind::ProviderTee, key: addr(&tee).to_vec(), model: Some(DS.into()), active: true },
        ],
        sponsors: vec![relay.id().to_string()],
        pool: botled_logic::ticket::PoolDomain { chain_id: 8453, pool: [0x33; 20] },
        reward_bridge: None,
    })?;
    let r = contract
        .call("new")
        .args_json(json!({"owner": root.id(), "timelock_secs": 86400, "mpc": "v1.signer.test.near", "settings": settings, "mpc_root": null}))
        .max_gas()
        .transact()
        .await?;
    println!("gas new: {:.2} Tgas", r.total_gas_burnt.as_gas() as f64 / 1e12);
    r.into_result()?;

    // signup through ft_on_transfer (USDC stand-in calls it directly)
    let base_key = key(0x42);
    let base = addr(&base_key);
    let msg: String = contract.view("signup_message").args_json(json!({"account": alice.id(), "base": hex(&base)})).await?.json()?;
    let ft_msg = json!({"signup": {"base": format!("0x{}", hex(&base)), "sig": psign(&base_key, msg.as_bytes())}}).to_string();
    let r = usdc
        .call(contract.id(), "ft_on_transfer")
        .args_json(json!({"sender_id": alice.id(), "amount": "20000000", "msg": ft_msg}))
        .max_gas()
        .transact()
        .await?;
    println!("gas signup (ft_on_transfer, EIP-191 ecrecover): {:.2} Tgas", r.total_gas_burnt.as_gas() as f64 / 1e12);
    r.into_result()?;

    let r = usdc
        .call(contract.id(), "ft_on_transfer")
        .args_json(json!({"sender_id": alice.id(), "amount": "1000000", "msg": "{\"topup\":{}}"}))
        .max_gas()
        .transact()
        .await?;
    println!("gas topup: {:.2} Tgas", r.total_gas_burnt.as_gas() as f64 / 1e12);
    r.into_result()?;

    // record_run with a ~2.6 KB request (kimi lane, gateway) and with the DeepSeek TEE key
    for (model, k, kind, case) in [(KIMI, &gw, Kind::Gateway, 0xccu8), (DS, &tee, Kind::ProviderTee, 0xcd)] {
        let user = format!("botled juror 0x{} round 1 case 0x{}\n{}", hex(&base), hex(&[case; 32]), "evidence ".repeat(200));
        let rq = format!(
            r#"{{"model":"{model}","messages":[{{"role":"system","content":{}}},{{"role":"user","content":{}}}],"stream":false}}"#,
            serde_json::to_string(&"constitution ".repeat(110))?,
            serde_json::to_string(&user)?
        );
        let rs = format!(r#"{{"model":"{model}","choices":[{{"message":{{"content":"{{}}"}}}}],"usage":{{"prompt_tokens":3120,"completion_tokens":2400}}}}"#);
        let text = signed_text(kind, model, &C.sha256(rq.as_bytes()), &C.sha256(rs.as_bytes()));
        use base64::Engine as _;
        let b64 = base64::engine::general_purpose::STANDARD;
        let r = relay
            .call(contract.id(), "record_run")
            .args_json(json!({"request": b64.encode(&rq), "response": b64.encode(&rs), "signer_id": if kind == Kind::Gateway {0} else {1}, "signature": psign(k, text.as_bytes())}))
            .max_gas()
            .transact()
            .await?;
        println!("gas record_run {model} ({} B request): {:.2} Tgas", rq.len(), r.total_gas_burnt.as_gas() as f64 / 1e12);
        let out: serde_json::Value = r.into_result()?.json()?;
        println!("   billed {}", out);
    }

    // ticket: penalty bookkeeping + EIP-712 digest + cross-contract call to the (absent) MPC signer
    let r = alice
        .call(contract.id(), "request_ticket")
        .args_json(json!({"no_shows_covered": 1, "session_key": "0x3333333333333333333333333333333333333333"}))
        .deposit(NearToken::from_yoctonear(1))
        .max_gas()
        .transact()
        .await?;
    let own: u64 = r.outcome().gas_burnt.as_gas();
    println!(
        "gas request_ticket: {:.2} Tgas in the registry call itself, {:.2} Tgas total (MPC sign + callback not available in sandbox)",
        own as f64 / 1e12,
        r.total_gas_burnt.as_gas() as f64 / 1e12
    );
    let view: serde_json::Value = contract.view("get_runner").args_json(json!({"account": alice.id()})).await?.json()?;
    println!("runner after: {view}");

    let runs: serde_json::Value = contract.view("get_runs").args_json(json!({"from": 0, "limit": 10})).await?.json()?;
    let runs = runs.as_array().unwrap();
    assert_eq!(runs.len(), 2, "both billed runs are in the audit ring");
    assert!(runs.iter().all(|r| r["sponsored"] == true && r["caller"] == relay.id().as_str()));
    println!("get_runs[0]: {}", runs[0]);
    let r = alice.call(contract.id(), "request_exit").max_gas().transact().await?;
    println!("gas request_exit: {:.2} Tgas", r.total_gas_burnt.as_gas() as f64 / 1e12);
    r.into_result()?;
    Ok(())
}
