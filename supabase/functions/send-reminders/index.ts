// =====================================================================
// Edge Function  send-reminders  (version 0.9, SQL file 16)
//
// Called ONLY by push_tick() in the database, through pg_net, about once a
// minute and only when a reminder is due. It signs each message with the
// VAPID keys and sends it to the phone's push service, then tells the
// database what happened (push_report): sent, gone (deleted), failed.
//
// Deploy with JWT verification OFF (pg_net sends no user token); the shared
// secret below is the lock instead:
//     supabase functions deploy send-reminders --no-verify-jwt
// or, in the dashboard editor, switch "Verify JWT" off for this function.
//
// Secrets (Edge Functions > Secrets). NEVER put them in this repository:
//   VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY   from: npx web-push generate-vapid-keys
//   VAPID_SUBJECT                         a mailto: address chosen by the maintainer
//   PUSH_SHARED_SECRET                    the same value as the Vault secret push_shared_secret
// Supabase adds SUPABASE_URL and SUPABASE_SECRET_KEYS by itself.
//
// Logs counts only: never an address, a key or a name.
// =====================================================================
import webpush from "npm:web-push@3.6.7";

const env = (name: string) => Deno.env.get(name) ?? "";
const TTL_SECONDS = 1800; // a reminder not delivered within 30 minutes is dropped, so 06:30 never shows in the afternoon

type Message = {
  endpoint: string;
  p256dh: string;
  auth: string;
  title: string;
  body: string;
  kind: string;
};

// The project's secret key, for push_report (it bypasses row-level security, so it stays on this server).
function secretKey(): string {
  try {
    const keys = JSON.parse(env("SUPABASE_SECRET_KEYS") || "{}");
    if (keys.default) return keys.default;
  } catch {
    /* fall through to the legacy key */
  }
  return env("SUPABASE_SERVICE_ROLE_KEY");
}

// The same length both ways, so the comparison takes the same time whatever is sent.
function sameSecret(given: string, expected: string): boolean {
  if (!expected || given.length !== expected.length) return false;
  let diff = 0;
  for (let i = 0; i < expected.length; i++)
    diff |= given.charCodeAt(i) ^ expected.charCodeAt(i);
  return diff === 0;
}

Deno.serve(async (req) => {
  if (
    req.method !== "POST" ||
    !sameSecret(
      req.headers.get("x-push-secret") ?? "",
      env("PUSH_SHARED_SECRET"),
    )
  ) {
    return new Response("unauthorized", { status: 401 });
  }
  let messages: Message[] = [];
  try {
    const data = await req.json();
    messages = Array.isArray(data?.messages)
      ? data.messages.slice(0, 5000)
      : [];
  } catch {
    return new Response("bad request", { status: 400 });
  }

  webpush.setVapidDetails(
    env("VAPID_SUBJECT"),
    env("VAPID_PUBLIC_KEY"),
    env("VAPID_PRIVATE_KEY"),
  );
  const sent: string[] = [],
    gone: string[] = [],
    failed: string[] = [];
  await Promise.all(
    messages.map(async (m) => {
      try {
        await webpush.sendNotification(
          { endpoint: m.endpoint, keys: { p256dh: m.p256dh, auth: m.auth } },
          JSON.stringify({ title: m.title, body: m.body, kind: m.kind }),
          { TTL: TTL_SECONDS },
        );
        sent.push(m.endpoint);
      } catch (error) {
        const status = (error as { statusCode?: number })?.statusCode;
        (status === 404 || status === 410 ? gone : failed).push(m.endpoint); // 404 / 410: the phone stopped using that address
      }
    }),
  );

  const key = secretKey();
  const report = await fetch(env("SUPABASE_URL") + "/rest/v1/rpc/push_report", {
    method: "POST",
    headers: { apikey: key, "Content-Type": "application/json" }, // the new secret keys go on apikey only, never as a Bearer token
    body: JSON.stringify({ p_sent: sent, p_gone: gone, p_failed: failed }),
  }).catch(() => null);

  const counts = {
    sent: sent.length,
    gone: gone.length,
    failed: failed.length,
  };
  console.log(
    JSON.stringify({
      ...counts,
      report: report ? report.status : "unreachable",
    }),
  );
  return Response.json(counts);
});
