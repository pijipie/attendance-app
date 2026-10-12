// Test for the Edge Function supabase/functions/send-reminders (version 0.9).
// It runs the real function file with Deno, against a fake push service (HTTPS, self-signed) and a fake
// database, with VAPID and phone keys made for this test only. Nothing leaves this computer.
// Run (Linux / WSL, needs deno and openssl), from the repository folder:
//   deno run -A --unsafely-ignore-certificate-errors tests/edge/send_reminders_test.ts
import webpush from "npm:web-push@3.6.7";

const results: [string, boolean][] = [];
function check(name: string, ok: boolean, extra: unknown = "") {
  results.push([name, ok]);
  console.log(
    (ok ? "PASS " : "FAIL ") +
      name +
      (!ok && extra !== "" ? "  -> " + JSON.stringify(extra) : ""),
  );
}
const b64url = (bytes: Uint8Array) =>
  btoa(String.fromCharCode(...bytes))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");

// 1. keys made for this test only
const vapid = webpush.generateVAPIDKeys();
const phone = await crypto.subtle.generateKey(
  { name: "ECDH", namedCurve: "P-256" },
  true,
  ["deriveBits"],
);
const p256dh = b64url(
  new Uint8Array(await crypto.subtle.exportKey("raw", phone.publicKey)),
);
const auth = b64url(crypto.getRandomValues(new Uint8Array(16)));
const dir = await Deno.makeTempDir();
await new Deno.Command("openssl", {
  args: [
    "req",
    "-x509",
    "-newkey",
    "rsa:2048",
    "-nodes",
    "-days",
    "1",
    "-subj",
    "/CN=127.0.0.1",
    "-keyout",
    dir + "/key.pem",
    "-out",
    dir + "/cert.pem",
  ],
  stdout: "null",
  stderr: "null",
}).output();

// 2. a fake push service: /ok answers 201, /gone 410, /fail 500
const pushed: {
  path: string;
  headers: Record<string, string>;
  size: number;
}[] = [];
const pushServer = Deno.serve(
  {
    port: 8781,
    hostname: "127.0.0.1",
    cert: await Deno.readTextFile(dir + "/cert.pem"),
    key: await Deno.readTextFile(dir + "/key.pem"),
    onListen() {},
  },
  async (req) => {
    const body = new Uint8Array(await req.arrayBuffer());
    const path = new URL(req.url).pathname;
    pushed.push({
      path,
      headers: Object.fromEntries(req.headers),
      size: body.length,
    });
    return new Response(null, {
      status: path === "/ok" ? 201 : path === "/gone" ? 410 : 500,
    });
  },
);

// 3. a fake database: records push_report
const reports: {
  headers: Record<string, string>;
  body: Record<string, string[]>;
}[] = [];
const dbServer = Deno.serve(
  { port: 8782, hostname: "127.0.0.1", onListen() {} },
  async (req) => {
    reports.push({
      headers: Object.fromEntries(req.headers),
      body: await req.json(),
    });
    return Response.json({ ok: true });
  },
);

// 4. the real function, in its own process, with test secrets
const fn = new Deno.Command("deno", {
  args: [
    "run",
    "-A",
    "--unsafely-ignore-certificate-errors",
    "supabase/functions/send-reminders/index.ts",
  ],
  env: {
    VAPID_PUBLIC_KEY: vapid.publicKey,
    VAPID_PRIVATE_KEY: vapid.privateKey,
    VAPID_SUBJECT: "mailto:test@example.test",
    PUSH_SHARED_SECRET: "test-shared-secret",
    NODE_TLS_REJECT_UNAUTHORIZED: "0", // the fake push service has a self-signed certificate (this test only)
    SUPABASE_URL: "http://127.0.0.1:8782",
    SUPABASE_SECRET_KEYS: JSON.stringify({ default: "sb_secret_test_only" }),
  },
  stdout: "piped",
  stderr: "piped",
}).spawn();
const out: string[] = [];
(async () => {
  for await (const chunk of fn.stdout.pipeThrough(new TextDecoderStream()))
    out.push(chunk);
})();
(async () => {
  for await (const chunk of fn.stderr.pipeThrough(new TextDecoderStream()))
    out.push(chunk);
})();
const call = (
  headers: Record<string, string>,
  body: unknown,
  method = "POST",
) =>
  fetch("http://127.0.0.1:8000/", {
    method,
    headers: { "Content-Type": "application/json", ...headers },
    body: method === "POST" ? JSON.stringify(body) : undefined,
  });
for (let i = 0; i < 100; i++) {
  // wait until it listens
  try {
    await (await call({}, {})).body?.cancel();
    break;
  } catch {
    await new Promise((r) => setTimeout(r, 200));
  }
}

// 5. the lock
const msg = (path: string) => ({
  endpoint: "https://127.0.0.1:8781" + path,
  p256dh,
  auth,
  title: "Kehadiran Staf",
  body: "Kehadiran anda belum direkod.",
  kind: "R2",
});
let r = await call({}, { messages: [msg("/ok")] });
check("no secret: 401", r.status === 401);
await r.body?.cancel();
r = await call({ "x-push-secret": "wrong" }, { messages: [msg("/ok")] });
check("wrong secret: 401", r.status === 401);
await r.body?.cancel();
r = await call({ "x-push-secret": "test-shared-secret" }, null, "GET");
check("GET: 401", r.status === 401);
await r.body?.cancel();
check(
  "nothing sent without the secret",
  pushed.length === 0 && reports.length === 0,
  { pushed: pushed.length, reports: reports.length },
);

// 6. three messages: sent, gone, failed
r = await call(
  { "x-push-secret": "test-shared-secret" },
  { messages: [msg("/ok"), msg("/gone"), msg("/fail")] },
);
const counts = await r.json();
check(
  "answer counts sent / gone / failed",
  r.status === 200 &&
    counts.sent === 1 &&
    counts.gone === 1 &&
    counts.failed === 1,
  counts,
);
const ok = pushed.find((p) => p.path === "/ok");
check(
  "one push per phone",
  pushed.length === 3,
  pushed.map((p) => p.path),
);
check(
  "push is encrypted (aes128gcm) with a body",
  ok?.headers["content-encoding"] === "aes128gcm" && (ok?.size ?? 0) > 0,
  ok,
);
check(
  "push is signed with the VAPID key",
  (ok?.headers["authorization"] ?? "").startsWith("vapid t=") &&
    (ok?.headers["authorization"] ?? "").includes("k=" + vapid.publicKey),
  ok?.headers["authorization"],
);
check(
  "push lives 30 minutes (TTL 1800)",
  ok?.headers["ttl"] === "1800",
  ok?.headers["ttl"],
);
const rep = reports[0];
check(
  "push_report: sent / gone / failed addresses",
  JSON.stringify(rep?.body) ===
    JSON.stringify({
      p_sent: ["https://127.0.0.1:8781/ok"],
      p_gone: ["https://127.0.0.1:8781/gone"],
      p_failed: ["https://127.0.0.1:8781/fail"],
    }),
  rep?.body,
);
check(
  "push_report: secret key on apikey only, no Bearer",
  rep?.headers["apikey"] === "sb_secret_test_only" &&
    !rep?.headers["authorization"],
  rep?.headers,
);
await new Promise((res) => setTimeout(res, 300));
const log = out.join("");
check(
  "log has the counts",
  log.includes('"sent":1') &&
    log.includes('"gone":1') &&
    log.includes('"failed":1'),
  log,
);
check(
  "log has no address, key or words",
  !log.includes("8781") &&
    !log.includes(p256dh) &&
    !log.includes(auth) &&
    !log.includes("direkod") &&
    !log.includes("sb_secret"),
  log,
);

fn.kill();
await fn.status;
await pushServer.shutdown();
await dbServer.shutdown();
await Deno.remove(dir, { recursive: true });
console.log(
  `${results.filter(([, o]) => o).length} of ${results.length} passed`,
);
Deno.exit(results.every(([, o]) => o) ? 0 : 1);
