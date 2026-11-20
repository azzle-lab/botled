// Local NEAR AI stand-in for e2e: same HTTP surface as cloud-api.near.ai (/v1/chat/completions, /v1/signature/{id}),
// same signed texts (gateway `rq:rs`, provider_tee `model:rq:rs`, EIP-191). Test keys only.
import { createServer, type Server } from "node:http";
import type { LocalAccount } from "viem";
import { sha256hex } from "../request.ts";

export type MockNearAiOpts = {
  gateway: LocalAccount; // signs gateway-kind receipts (kimi lane)
  tee: Record<string, LocalAccount>; // model -> its own TEE key (provider_tee receipts)
  decide: (runner: string, model: string, n: number) => { outcome: string; workerBps: number };
};

export class MockNearAi {
  readonly opts: MockNearAiOpts;
  readonly calls: { model: string; runner: string }[] = [];
  private runs = new Map<string, { model: string; rq: string; rs: string }>();
  constructor(opts: MockNearAiOpts) { this.opts = opts; }

  listen(port: number): Promise<Server> {
    const srv = createServer(async (req, res) => {
      const chunks: Buffer[] = [];
      for await (const ch of req) chunks.push(ch as Buffer);
      const body = new Uint8Array(Buffer.concat(chunks));
      const url = new URL(req.url!, "http://x");
      if (req.method === "POST" && url.pathname === "/v1/chat/completions") {
        const j = JSON.parse(new TextDecoder().decode(body));
        const runner = /botled juror (0x[0-9a-f]{40})/.exec(j.messages[1].content)?.[1] ?? "?";
        const n = this.calls.push({ model: j.model, runner });
        const id = `chatcmpl-mock-${n}`;
        const content = JSON.stringify({ ...this.opts.decide(runner, j.model, n), reason: "Scope criteria checked against the delivery." });
        const resp = Buffer.from(
          JSON.stringify({
            id, object: "chat.completion", created: 1763600000 + n, model: j.model,
            choices: [{ index: 0, message: { role: "assistant", reasoning_content: "Checked scope vs delivery.", content }, finish_reason: "stop" }],
            usage: { prompt_tokens: 3100, completion_tokens: 900, total_tokens: 4000 },
          }),
        );
        this.runs.set(id, { model: j.model, rq: sha256hex(body), rs: sha256hex(resp) });
        res.writeHead(200, { "content-type": "application/json" }).end(resp);
        return;
      }
      const m = /^\/v1\/signature\/(.+)$/.exec(url.pathname);
      if (req.method === "GET" && m) {
        const run = this.runs.get(decodeURIComponent(m[1]));
        if (!run || url.searchParams.get("signing_algo") !== "ecdsa") return void res.writeHead(404).end("{}");
        const tee = this.opts.tee[run.model];
        const text = tee ? `${run.model}:${run.rq}:${run.rs}` : `${run.rq}:${run.rs}`;
        const key = tee ?? this.opts.gateway;
        const signature = await key.signMessage!({ message: text });
        res.writeHead(200, { "content-type": "application/json" }).end(
          JSON.stringify({ text, signature, signing_address: key.address, signing_algo: "ecdsa" }),
        );
        return;
      }
      res.writeHead(404).end("{}");
    });
    return new Promise((ok) => srv.listen(port, "127.0.0.1", () => ok(srv)));
  }
}
