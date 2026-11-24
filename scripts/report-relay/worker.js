// Macximesed bug-report relay (Cloudflare Worker).
//
// Takes an encrypted report (the MXR1 envelope macx makes) and passes it on, unread, to a private Discord channel.
// It can't read reports: they're encrypted on the Mac to the maintainer's key. It keeps no IP addresses: request
// logs are off (wrangler.toml), nothing here logs, and the rate limiter only counts per address for a minute.
// The Discord webhook address lives only in the DISCORD_WEBHOOK secret, never in macx or the repo.

const MAX_BYTES = 256_000 + 64; // macx caps a report at 256 KB; the envelope adds 53 bytes
const MIN_BYTES = 5 + 32 + 16; // header, encapsulated key, authentication tag
const MAGIC = [0x4d, 0x58, 0x52, 0x31]; // "MXR1"

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.method !== "POST" || url.pathname !== "/report") {
      return new Response("Not found", { status: 404 });
    }
    const declared = Number(request.headers.get("content-length") || "0");
    if (!declared || declared > MAX_BYTES) {
      return new Response("Too big", { status: 413 });
    }
    if (env.LIMITER) {
      const { success } = await env.LIMITER.limit({ key: request.headers.get("cf-connecting-ip") || "unknown" });
      if (!success) return new Response("Too many reports, try again in a minute", { status: 429 });
    }
    const body = new Uint8Array(await request.arrayBuffer());
    if (body.length < MIN_BYTES || body.length > MAX_BYTES || MAGIC.some((b, i) => body[i] !== b)) {
      return new Response("Not a report", { status: 400 });
    }
    if (!env.DISCORD_WEBHOOK) {
      return new Response("Not set up", { status: 503 });
    }

    const id = crypto.randomUUID();
    const form = new FormData();
    form.append(
      "payload_json",
      JSON.stringify({
        content: `report ${id}, ${body.length} bytes, key ${body[4]}`,
        allowed_mentions: { parse: [] },
      }),
    );
    form.append("files[0]", new Blob([body], { type: "application/octet-stream" }), `${id}.mxr`);
    const sent = await fetch(env.DISCORD_WEBHOOK, { method: "POST", body: form });
    if (!sent.ok) {
      return new Response("Couldn't pass it on", { status: 502 });
    }
    return Response.json({ id });
  },
};
