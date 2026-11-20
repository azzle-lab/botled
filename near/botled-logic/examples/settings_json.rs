//! Prints registry `new` Settings JSON (exactly the serde shape the contract parses).
//!   cargo run -q -p botled-logic --example settings_json -- <usdc> <profit_to> <dev_to> <penalty_to> <sponsor> <pool 0x..> <chain_id> <gateway 0x..>
use botled_logic::receipt::{Kind, Scheme, SignerKey};
use botled_logic::registry::{LanePrice, Params, Settings};
use botled_logic::ticket::PoolDomain;

fn h20(s: &str) -> [u8; 20] {
    let s = s.trim_start_matches("0x");
    let mut o = [0u8; 20];
    for i in 0..20 {
        o[i] = u8::from_str_radix(&s[2 * i..2 * i + 2], 16).unwrap();
    }
    o
}

fn main() {
    let a: Vec<String> = std::env::args().skip(1).collect();
    let s = Settings {
        params: Params::default(),
        usdc: a[0].clone(),
        profit_to: a[1].clone(),
        dev_to: a[2].clone(),
        penalty_to: a[3].clone(),
        lanes: vec![
            LanePrice { model: "moonshotai/kimi-k3".into(), input_per_mtok: 3_300_000, output_per_mtok: 16_500_000, receipt_kind: Kind::Gateway },
        ],
        signers: vec![SignerKey { scheme: Scheme::Ecdsa, kind: Kind::Gateway, key: h20(&a[7]).to_vec(), model: None, active: true }],
        sponsors: vec![a[4].clone()],
        pool: PoolDomain { chain_id: a[6].parse().unwrap(), pool: h20(&a[5]) },
        reward_bridge: None,
    };
    println!("{}", serde_json::to_string(&s).unwrap());
}
