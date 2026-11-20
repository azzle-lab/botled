// NEAR Chain Signatures (v1.signer, secp256k1 domain 0): the runner's NEAR account controls its Base address.
//   tweak    = sha3_256("near-mpc-recovery v0.1.0 epsilon derivation:" + predecessor + "," + path)
//   child_pk = root_pk + tweak·G         address = keccak256(x‖y)[12:]
// Signing: call v1.signer.sign({request:{path, payload_v2:{Ecdsa:"<32-byte hex>"}, domain_id:0}}) with ≥1 yoctoNEAR
// and ≥15 Tgas from the runner's own account; the MPC returns {big_r:{affine_point}, s:{scalar}, recovery_id}.
import { secp256k1 } from "@noble/curves/secp256k1";
import { sha3_256, keccak_256 } from "@noble/hashes/sha3";
import { bytesToHex, hexToBytes } from "@noble/hashes/utils";

export const MAINNET_SIGNER = "v1.signer";
export const TESTNET_SIGNER = "v1.signer-prod.testnet";
export const TESTNET_ROOT =
  "secp256k1:4NfTiv3UsGahebgTaHyD9vF8KYKMBnfd6kh94mK6xv8fGBiJB8TBtFMP5WWXz6B89Ac1fbpzPwAvoyQebemHFwx3";
export const MAINNET_ROOT =
  "secp256k1:3tFRbMqmoa6AAALMrEFAYCEoHcqKxeW38YptwowBVBtXK1vo36HDbUWuR6EZmoK4JcH6HDkNMGGqP1ouV7VZUWya";
export const BASE_PATH = "base-1"; // botled-registry::BASE_PATH
export const ENROLL_PATH = "botled-enroll-v1"; // registry's own path -> BotledNearConfig.enrollSigner

const B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
export function base58Decode(s: string): Uint8Array {
  let n = 0n;
  for (const c of s) {
    const i = B58.indexOf(c);
    if (i < 0) throw new Error("base58");
    n = n * 58n + BigInt(i);
  }
  const hex = n.toString(16).padStart(2, "0");
  const body = hexToBytes(hex.length % 2 ? "0" + hex : hex);
  const zeros = s.match(/^1*/)![0].length;
  return new Uint8Array([...new Uint8Array(zeros), ...body]);
}

export function nearSecpKey(s: string): Uint8Array {
  const raw = base58Decode(s.replace(/^secp256k1:/, ""));
  if (raw.length !== 64) throw new Error("expected 64-byte secp256k1 key");
  return new Uint8Array([4, ...raw]);
}

export function derivePublicKey(root: string, predecessor: string, path: string): Uint8Array {
  const tweak = sha3_256(`near-mpc-recovery v0.1.0 epsilon derivation:${predecessor},${path}`);
  const t = BigInt("0x" + bytesToHex(tweak)) % secp256k1.CURVE.n;
  const child = secp256k1.ProjectivePoint.fromHex(nearSecpKey(root)).add(secp256k1.ProjectivePoint.BASE.multiply(t));
  return child.toRawBytes(false);
}

export function addressOf(pk65: Uint8Array): `0x${string}` {
  return `0x${bytesToHex(keccak_256(pk65.slice(1)).slice(12))}`;
}

export function deriveBaseAddress(nearAccount: string, path = BASE_PATH, root = MAINNET_ROOT): `0x${string}` {
  return addressOf(derivePublicKey(root, nearAccount, path));
}

export type MpcSignature = { big_r: { affine_point: string }; s: { scalar: string }; recovery_id: number };

/** v1.signer response -> 65-byte r‖s‖v (v = 27/28) for ecrecover / OpenZeppelin ECDSA. */
export function mpcToEvm(sig: MpcSignature): `0x${string}` {
  const r = sig.big_r.affine_point.slice(2).padStart(64, "0"); // drop 02/03 prefix
  const s = sig.s.scalar.padStart(64, "0");
  return `0x${r}${s}${(27 + sig.recovery_id).toString(16)}`;
}

/** args for v1.signer.sign of a 32-byte digest */
export function signArgs(digest: `0x${string}`, path: string) {
  return { request: { path, payload_v2: { Ecdsa: digest.slice(2) }, domain_id: 0 } };
}
