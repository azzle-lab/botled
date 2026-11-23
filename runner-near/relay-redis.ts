// Upstash Redis (REST) seat store for SponsorRelay on serverless hosting. No SDK: plain fetch.
import type { SeatStore, SponsoredReceipt } from "./relay.ts";

export class RedisSeatStore implements SeatStore {
  private url: string; private token: string; private prefix: string;
  constructor(url: string, token: string, prefix: string) { this.url = url; this.token = token; this.prefix = prefix; }
  private async cmd(...args: (string | number)[]): Promise<any> {
    const r = await fetch(this.url, { method: "POST", headers: { authorization: `Bearer ${this.token}`, "content-type": "application/json" }, body: JSON.stringify(args.map(String)) });
    const b = await r.json();
    if (!r.ok || b.error) throw new Error(`redis: ${b.error ?? r.status}`);
    return b.result;
  }
  async get(key: string) {
    const v = await this.cmd("HGET", `${this.prefix}:seats`, key);
    return v ? (JSON.parse(v) as SponsoredReceipt) : undefined;
  }
  async claim(key: string, ttlSec: number) {
    return (await this.cmd("SET", `${this.prefix}:claim:${key}`, "1", "NX", "EX", ttlSec)) === "OK";
  }
  async put(key: string, rc: SponsoredReceipt) {
    await this.cmd("HSET", `${this.prefix}:seats`, key, JSON.stringify(rc));
    await this.cmd("PERSIST", `${this.prefix}:claim:${key}`); // signed: this seat is closed for good
  }
  async release(key: string) {
    await this.cmd("DEL", `${this.prefix}:claim:${key}`);
  }
  async list() {
    const flat: string[] = (await this.cmd("HGETALL", `${this.prefix}:seats`)) ?? [];
    const out: [string, SponsoredReceipt][] = [];
    for (let i = 0; i < flat.length; i += 2) out.push([flat[i], JSON.parse(flat[i + 1])]);
    return out;
  }
}
