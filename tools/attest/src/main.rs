//! botled-attest <report.json> --model <id> --nonce <hex32> [--expect-ecdsa 0x..] [--expect-ed25519 hex] [--pccs URL]
//!
//! Verifies ONE NEAR AI model attestation report (GET /v1/attestation/report?model=&signing_algo=&nonce=):
//!   1. Intel TDX quote v4: full DCAP verification with dcap-qvl (quote signature -> attestation key -> QE report ->
//!      PCK cert chain -> Intel SGX Root CA pinned inside dcap-qvl; Intel-signed TCB info + QE identity + CRLs from a
//!      PCCS/PCS, which is only a transport). Prints the TCB status.
//!   2. report_data binds the signing key AND our fresh nonce:
//!        ecdsa   : address(20) || 0^12 || nonce(32)       ed25519 : pubkey(32) || nonce(32)
//!      and for ecdsa, keccak256(signing_public_key)[12:] == signing_address.
//!   3. The quote's MRTD / RTMR0..3 equal the report's tcb_info, and RTMR3 equals the replay of the event log.
//!   4. The event log's `compose-hash` event equals sha256(app_compose) == tcb_info.compose_hash, so the docker
//!      compose (images, model) is what the TD measured; prints the model id(s) found in the compose.
//! Exit code 0 only if every check passes. Output: one JSON object on stdout.
use anyhow::{anyhow, bail, ensure, Context, Result};
use serde_json::{json, Value};
use sha2::{Digest, Sha256, Sha384};
use sha3::Keccak256;

fn arg(args: &[String], k: &str) -> Option<String> {
    args.iter().position(|a| a == k).and_then(|i| args.get(i + 1).cloned())
}
fn unhex(s: &str) -> Result<Vec<u8>> {
    Ok(hex::decode(s.trim_start_matches("0x"))?)
}
fn s<'a>(v: &'a Value, k: &str) -> Result<&'a str> {
    v.get(k).and_then(Value::as_str).ok_or_else(|| anyhow!("missing {k}"))
}

/// Python `json.dumps(v, sort_keys=True, separators=(",", ":"))` (ASCII-escaped), independent of serde map order.
fn canonical(v: &Value) -> String {
    match v {
        Value::Object(m) => {
            let mut keys: Vec<&String> = m.keys().collect();
            keys.sort();
            let parts: Vec<String> = keys.iter().map(|k| format!("{}:{}", ascii(&Value::String((*k).clone())), canonical(&m[*k]))).collect();
            format!("{{{}}}", parts.join(","))
        }
        Value::Array(a) => format!("[{}]", a.iter().map(canonical).collect::<Vec<_>>().join(",")),
        Value::String(_) => ascii(v),
        other => other.to_string(),
    }
}
fn ascii(v: &Value) -> String {
    let raw = v.to_string();
    let mut out = String::with_capacity(raw.len());
    for c in raw.chars() {
        if c.is_ascii() {
            out.push(c);
        } else {
            let mut buf = [0u16; 2];
            for u in c.encode_utf16(&mut buf) {
                out.push_str(&format!("\\u{:04x}", u));
            }
        }
    }
    out
}

#[tokio::main]
async fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let path = args.get(1).context("usage: botled-attest <report.json> --model <id> --nonce <hex>")?;
    let model = arg(&args, "--model").context("--model")?;
    let nonce = arg(&args, "--nonce").context("--nonce")?.to_lowercase();
    let pccs = arg(&args, "--pccs").unwrap_or_else(|| dcap_qvl::PHALA_PCCS_URL.to_string());
    let report: Value = serde_json::from_str(&std::fs::read_to_string(path)?)?;
    // `--model gateway` verifies the NEAR AI gateway's own attestation (the key that signs kimi-k3 receipts)
    let m = if model == "gateway" {
        report.get("gateway_attestation").filter(|g| !g.is_null()).ok_or_else(|| anyhow!("no gateway attestation"))?
    } else {
        report["model_attestations"]
            .as_array()
            .and_then(|a| a.iter().find(|m| m["model_name"] == model.as_str()))
            .ok_or_else(|| anyhow!("no attestation for {model}"))?
    };
    let algo = s(m, "signing_algo")?;
    let mut out = json!({"model": model, "signing_algo": algo});

    // 1. DCAP
    let quote = unhex(s(m, "intel_quote")?)?;
    let collateral = dcap_qvl::collateral::CollateralClient::with_default_http(pccs.as_str())?
        .fetch(&quote)
        .await
        .context("collateral")?;
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)?.as_secs();
    let v = dcap_qvl::verify::verify(&quote, &collateral, now).map_err(|e| anyhow!("DCAP verify failed: {e:?}"))?;
    let td = v.report.as_td10().ok_or_else(|| anyhow!("not a TDX quote"))?;
    out["tcb_status"] = json!(v.status);
    out["advisory_ids"] = json!(v.advisory_ids);
    let ok_status = ["UpToDate", "SWHardeningNeeded", "ConfigurationAndSWHardeningNeeded"];
    out["tcb_status_acceptable"] = json!(ok_status.contains(&v.status.as_str()));

    // 2. report_data binding
    let rd = td.report_data;
    ensure!(hex::encode(&rd[32..]) == nonce, "report_data does not carry our nonce (replayed report?)");
    ensure!(s(m, "request_nonce")?.to_lowercase() == nonce, "request_nonce mismatch");
    let key = match algo {
        "ecdsa" => {
            let addr = unhex(s(m, "signing_address")?)?;
            ensure!(addr.len() == 20 && rd[..20] == addr[..] && rd[20..32].iter().all(|b| *b == 0), "report_data != signing_address");
            // the gateway report carries only the address (the quote binds it directly); model reports also give the pubkey
            if let Ok(pkh) = s(m, "signing_public_key") {
                let pk = unhex(pkh)?;
                let pk = if pk.len() == 65 { pk[1..].to_vec() } else { pk };
                ensure!(pk.len() == 64, "signing_public_key length");
                ensure!(Keccak256::digest(&pk)[12..] == addr[..], "signing_public_key does not hash to signing_address");
            }
            format!("0x{}", hex::encode(addr))
        }
        "ed25519" => {
            let pk = unhex(s(m, "signing_address")?)?;
            ensure!(pk.len() == 32 && rd[..32] == pk[..], "report_data != ed25519 key");
            hex::encode(pk)
        }
        a => bail!("unknown algo {a}"),
    };
    out["attested_key"] = json!(key);
    if let Some(e) = arg(&args, "--expect-ecdsa").filter(|_| algo == "ecdsa") {
        ensure!(e.to_lowercase() == key, "attested ECDSA key {key} != configured {e}");
        out["matches_configured"] = json!(true);
    }
    if let Some(e) = arg(&args, "--expect-ed25519").filter(|_| algo == "ed25519") {
        ensure!(e.to_lowercase().trim_start_matches("0x") == key, "attested ed25519 key {key} != configured {e}");
        out["matches_configured"] = json!(true);
    }

    // 3. measurements = tcb_info, RTMR3 = event-log replay
    let tcb_owned: Value = match &m["info"]["tcb_info"] {
        Value::String(t) => serde_json::from_str(t)?,
        v => v.clone(),
    };
    let tcb = &tcb_owned;
    for (name, got) in [("mrtd", &td.mr_td), ("rtmr0", &td.rt_mr0), ("rtmr1", &td.rt_mr1), ("rtmr2", &td.rt_mr2), ("rtmr3", &td.rt_mr3)] {
        ensure!(hex::encode(got) == s(tcb, name)?, "{name} in quote != tcb_info");
    }
    let events = tcb["event_log"].as_array().context("event_log")?;
    let mut rtmr3 = [0u8; 48];
    let mut compose_event = None;
    for e in events.iter().filter(|e| e["imr"] == 3) {
        let d = unhex(s(e, "digest")?)?;
        let mut h = Sha384::new();
        h.update(rtmr3);
        h.update(&d);
        rtmr3.copy_from_slice(&h.finalize());
        if e["event"] == "compose-hash" {
            compose_event = Some(s(e, "event_payload")?.to_string());
        }
    }
    ensure!(rtmr3 == td.rt_mr3, "event log does not replay to RTMR3");

    // 4. compose binding
    let app_compose = s(tcb, "app_compose")?;
    let compose_hash = hex::encode(Sha256::digest(app_compose.as_bytes()));
    ensure!(compose_hash == s(tcb, "compose_hash")?, "sha256(app_compose) != compose_hash");
    ensure!(compose_event.as_deref() == Some(compose_hash.as_str()), "compose-hash event != sha256(app_compose)");
    out["compose_hash"] = json!(compose_hash);
    out["compose_mentions_model"] = json!(app_compose.contains(&model));
    let ac: Value = serde_json::from_str(app_compose).unwrap_or(Value::Null);
    let dc = ac["docker_compose_file"].as_str().unwrap_or("");
    let images: Vec<&str> = dc.lines().filter_map(|l| l.trim().strip_prefix("image:")).map(str::trim).collect();
    out["images"] = json!(images);
    let variants: Vec<String> = dc
        .split(|c: char| c.is_whitespace() || c == '"' || c == '\'' || c == ',' || c == '=')
        .filter(|t| t.contains("DeepSeek") || t.contains("dsv4") || t.contains("abliterated"))
        .map(String::from)
        .collect::<std::collections::BTreeSet<_>>()
        .into_iter()
        .collect();
    out["model_tokens_in_compose"] = json!(variants);
    out["mrtd"] = json!(hex::encode(td.mr_td));

    // 5. compose-manager attestation (the model workload is started by NEAR AI's compose-manager inside the SAME TD):
    //    its own DCAP quote with report_data = sha256(canonical JSON of the action log) || nonce
    let cm = &m["compose_manager_attestation"];
    if !cm.is_null() {
        let cq = unhex(s(cm, "quote")?)?;
        let ccol = dcap_qvl::collateral::CollateralClient::with_default_http(pccs.as_str())?.fetch(&cq).await?;
        let cv = dcap_qvl::verify::verify(&cq, &ccol, now).map_err(|e| anyhow!("compose-manager DCAP verify failed: {e:?}"))?;
        let ctd = cv.report.as_td10().ok_or_else(|| anyhow!("compose-manager quote not TDX"))?;
        ensure!(
            ctd.mr_td == td.mr_td && ctd.rt_mr0 == td.rt_mr0 && ctd.rt_mr1 == td.rt_mr1 && ctd.rt_mr2 == td.rt_mr2,
            "compose-manager quote is from a different TD"
        );
        let actions = cm["actions"].as_array().context("actions")?;
        let canon = canonical(&cm["actions"]);
        let ah = Sha256::digest(canon.as_bytes());
        ensure!(hex::encode(ah) == s(cm, "actions_hash")?, "actions_hash != sha256(canonical(actions))");
        ensure!(ctd.report_data[..32] == ah[..] && hex::encode(&ctd.report_data[32..]) == nonce, "compose-manager report_data != actions_hash || nonce");
        let last_up = actions.iter().rev().find(|a| a["action"] == "compose_up" && a["file"].as_str().map_or(false, |f| !f.contains("rotate")));
        out["compose_manager"] = json!({
            "tcb_status": cv.status,
            "same_td": true,
            "actions": actions.len(),
            "actions_hash": hex::encode(ah),
            "last_compose_up": last_up,
        });
        if let Some(services) = last_up.and_then(|a| a["services"].as_array()) {
            let odd: Vec<&Value> = services.iter().filter(|x| x.as_str().map_or(false, |x| x.contains("abliterated"))).collect();
            out["compose_manager"]["variant_services_in_same_td"] = json!(odd);
        }
    }
    out["ok"] = json!(true);
    println!("{}", serde_json::to_string_pretty(&out)?);
    Ok(())
}
