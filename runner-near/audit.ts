// Relay audit: reconciles NEAR `botled-registry` billed runs (get_runs) with Base cage reveals.
// Everything read here is public; no keys. Findings:
//   UNBILLED_SPONSORED   counted (co-signed) reveal with no billed run for that exact receipt -> relay broke the
//                        "record_run before co-signing" rule (or the run fell out of the ring: OUT_OF_RING instead)
//   WITHHELD             a sponsored run WAS billed for the seat, but the seat revealed liveness-only or not at all
//                        after the reveal window -> the relay billed and did not deliver (or the runner dropped it).
//                        Attributed to the billing relay account. Censorship signal.
//   LIVENESS             liveness-only reveal and no sponsored run billed -> the relay refused / was unreachable
//   NO_SHOW              drawn, nothing revealed, nothing billed (after the reveal window)
//   SEAT_MISMATCH        billed run for a (runner, round, case) that is not a drawn seat of that round
// Per-relay counters let anyone compare relays: a relay that serves some runners and not others shows up as a high
// LIVENESS / WITHHELD share for exactly those runners.
import { decodeEventLog, type Hex, type PublicClient } from "viem";
import { cageAbi, poolAbi } from "./abi.ts";
import type { Near } from "./loop.ts";

export type RunLog = {
  index: number; runner: string; account: string; round: number; case: string; request_sha256: string;
  response_sha256: string; signer_id: number; model: string; caller: string; sponsored: boolean; charged: string; at: number;
};
export type Finding = { kind: string; arbitration?: Hex; taskId?: string; round?: number; runner?: string; relay?: string; detail?: string };
export type AuditReport = {
  cases: number; seats: number; reveals: { counted: number; liveness: number }; billed: { total: number; sponsored: number; byo: number };
  relays: Record<string, { billed: number; delivered: number; withheld: number }>;
  findings: Finding[]; ok: boolean;
};

export async function fetchRuns(near: Near, registry: string): Promise<{ runs: RunLog[]; firstInRing: number }> {
  const count = Number(await near.view<number>(registry, "run_count", {}));
  const runs: RunLog[] = [];
  const first = Math.max(0, count - 1024);
  for (let from = first; from < count; from += 200) runs.push(...(await near.view<RunLog[]>(registry, "get_runs", { from, limit: 200 })));
  return { runs, firstInRing: first };
}

export async function audit(o: {
  base: PublicClient; cage: Hex; pool: Hex; near: Near; registry: string; fromBlock?: bigint; toBlock?: bigint;
  /** treat runs older than this (unix s) as possibly rotated out of the ring */ ringStartAt?: number;
}): Promise<AuditReport> {
  const { base, cage, pool } = o;
  const logs = await base.getLogs({ address: cage, fromBlock: o.fromBlock ?? 0n, toBlock: o.toBlock ?? "latest" });
  const ev = logs.flatMap((l) => {
    try { return [decodeEventLog({ abi: cageAbi, data: l.data, topics: l.topics })]; } catch { return []; }
  });
  const now = (await base.getBlock()).timestamp;
  const { runs, firstInRing } = await fetchRuns(o.near, o.registry);
  const runKey = (runner: string, round: number, c: string) => `${runner.toLowerCase()}:${round}:${c.toLowerCase()}`;
  const runsBySeat = new Map<string, RunLog[]>();
  for (const r of runs) {
    const k = runKey(r.runner, r.round, r.case);
    runsBySeat.set(k, [...(runsBySeat.get(k) ?? []), r]);
  }
  const ringFloorAt = runs.length && firstInRing > 0 ? runs[0].at : 0;

  const rep: AuditReport = {
    cases: 0, seats: 0, reveals: { counted: 0, liveness: 0 },
    billed: { total: runs.length, sponsored: runs.filter((r) => r.sponsored).length, byo: runs.filter((r) => !r.sponsored).length },
    relays: {}, findings: [], ok: true,
  };
  for (const r of runs) if (r.sponsored) (rep.relays[r.caller] ??= { billed: 0, delivered: 0, withheld: 0 }).billed++;

  const seen = new Set<string>();
  const usedRuns = new Set<number>();
  const rounds = ev.filter((e) => e.eventName === "RoundStarted") as any[];
  const reveals = ev.filter((e) => e.eventName === "Revealed") as any[];
  const caseIds = new Set(rounds.map((e) => `${e.args.arbitration}:${e.args.taskId}`));
  rep.cases = caseIds.size;
  for (const e of rounds) {
    const { arbitration, taskId, round } = e.args;
    const c = await base.readContract({ address: cage, abi: cageAbi, functionName: "getCase", args: [arbitration, taskId] });
    const drawId = await base.readContract({ address: cage, abi: cageAbi, functionName: "drawId", args: [arbitration, taskId, round] });
    const drawn = await base.readContract({ address: pool, abi: poolAbi, functionName: "drawnRunners", args: [cage, drawId] });
    const [, revealEnd] = await base.readContract({ address: cage, abi: cageAbi, functionName: "windows", args: [arbitration, taskId] });
    const roundOver = c.round > round || (revealEnd !== 0n && now > revealEnd);
    for (const runner of drawn) {
      rep.seats++;
      const k = runKey(runner, round, c.inputHash);
      seen.add(k);
      const billed = runsBySeat.get(k) ?? [];
      billed.forEach((r) => usedRuns.add(r.index));
      const sponsoredRun = billed.find((r) => r.sponsored);
      const rv = reveals.find((x) => x.args.arbitration === arbitration && x.args.taskId === taskId && x.args.round === round && x.args.runner === runner);
      const at = { arbitration, taskId: taskId.toString(), round, runner };
      if (rv?.args.counted) {
        rep.reveals.counted++;
        const match = billed.find((r) => `0x${r.request_sha256}` === rv.args.requestHash && `0x${r.response_sha256}` === rv.args.responseHash);
        if (match) {
          (rep.relays[match.caller] ??= { billed: 0, delivered: 0, withheld: 0 }).delivered++;
        } else {
          const kind = ringFloorAt && Number(c.hardStop) < ringFloorAt ? "OUT_OF_RING" : "UNBILLED_SPONSORED";
          rep.findings.push({ kind, ...at, detail: `sponsorId ${rv.args.sponsorId}` });
        }
      } else if (rv) {
        rep.reveals.liveness++;
        if (sponsoredRun) {
          rep.relays[sponsoredRun.caller].withheld++;
          rep.findings.push({ kind: "WITHHELD", ...at, relay: sponsoredRun.caller, detail: "billed sponsored run, liveness-only reveal" });
        } else rep.findings.push({ kind: "LIVENESS", ...at, detail: billed.length ? "own-key run billed" : "no run billed" });
      } else if (roundOver) {
        if (sponsoredRun) {
          rep.relays[sponsoredRun.caller].withheld++;
          rep.findings.push({ kind: "WITHHELD", ...at, relay: sponsoredRun.caller, detail: "billed sponsored run, no reveal" });
        } else rep.findings.push({ kind: "NO_SHOW", ...at });
      }
    }
  }
  // billed runs for seats in audited cases that were never drawn
  const caseHashes = new Set<string>();
  for (const e of ev.filter((x) => x.eventName === "CaseOpened") as any[]) caseHashes.add(e.args.inputHash.toLowerCase());
  for (const r of runs) {
    if (!caseHashes.has(r.case.toLowerCase()) || usedRuns.has(r.index)) continue;
    if (!seen.has(runKey(r.runner, r.round, r.case))) rep.findings.push({ kind: "SEAT_MISMATCH", runner: r.runner, round: r.round, relay: r.caller, detail: `run #${r.index}` });
  }
  rep.ok = !rep.findings.some((f) => f.kind === "UNBILLED_SPONSORED" || f.kind === "WITHHELD" || f.kind === "SEAT_MISMATCH");
  return rep;
}
