// Tests for the relay, with Node's built-in runner: node --test scripts/report-relay/worker.test.mjs
// Discord is replaced by a fake fetch, so nothing leaves this machine.
import { test } from "node:test";
import assert from "node:assert/strict";
import worker from "./worker.js";

const WEBHOOK = "https://discord.invalid/api/webhooks/fake";

function envelope(size = 100) {
  const b = new Uint8Array(size);
  b.set([0x4d, 0x58, 0x52, 0x31, 1]); // "MXR1", key id 1
  return b;
}

function post(body, { path = "/report", length } = {}) {
  return new Request(`https://relay.invalid${path}`, {
    method: "POST",
    body,
    headers: { "content-length": String(length ?? body.length), "cf-connecting-ip": "203.0.113.7" },
  });
}

function fakeDiscord(status = 204) {
  const calls = [];
  globalThis.fetch = async (url, init) => {
    calls.push({ url, form: init.body });
    return new Response(null, { status });
  };
  return calls;
}

const env = (extra = {}) => ({ DISCORD_WEBHOOK: WEBHOOK, ...extra });

test("only POST /report is answered", async () => {
  fakeDiscord();
  assert.equal((await worker.fetch(new Request("https://relay.invalid/report"), env())).status, 404);
  assert.equal((await worker.fetch(post(envelope(), { path: "/" }), env())).status, 404);
});

test("too big, too small or not an envelope is refused, and nothing is forwarded", async () => {
  const calls = fakeDiscord();
  assert.equal((await worker.fetch(post(envelope(300_000)), env())).status, 413);
  assert.equal((await worker.fetch(post(envelope(20)), env())).status, 400);
  const junk = new TextEncoder().encode("x".repeat(100));
  assert.equal((await worker.fetch(post(junk), env())).status, 400);
  assert.equal(calls.length, 0);
});

test("a report is forwarded as a file with a fresh ID, and the ID comes back", async () => {
  const calls = fakeDiscord();
  const res = await worker.fetch(post(envelope(500)), env());
  assert.equal(res.status, 200);
  const { id } = await res.json();
  assert.match(id, /^[0-9a-f-]{36}$/);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, WEBHOOK);
  const file = calls[0].form.get("files[0]");
  assert.equal(file.name, `${id}.mxr`);
  assert.equal(file.size, 500);
  const payload = JSON.parse(calls[0].form.get("payload_json"));
  assert.deepEqual(payload.allowed_mentions, { parse: [] });
  assert.ok(!payload.content.includes("203.0.113.7"), "the sender's address isn't passed on");
});

test("a failing webhook or a hit rate limit says so", async () => {
  fakeDiscord(500);
  assert.equal((await worker.fetch(post(envelope()), env())).status, 502);
  fakeDiscord();
  const limiter = { limit: async () => ({ success: false }) };
  assert.equal((await worker.fetch(post(envelope()), env({ LIMITER: limiter }))).status, 429);
  assert.equal((await worker.fetch(post(envelope()), { DISCORD_WEBHOOK: "" })).status, 503);
});
