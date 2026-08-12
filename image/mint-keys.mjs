// Mint the two Supabase-shaped API keys from the deployment's signing secret.
//
// This is the reason the whole stack has to live in one container. The key the
// browser uses is not a random string - it is a token signed with the same
// secret GoTrue and PostgREST verify against. Railway's template variables can
// generate a random secret, but they cannot sign anything with it, so the keys
// have to be derived at boot by something that already holds the secret.
//
// Deriving them (rather than storing them) also means they survive a redeploy
// unchanged: same secret in, same keys out, so a browser session and an already
// configured MCP client keep working.
import { createHmac } from "node:crypto";

const b64url = (buf) =>
  Buffer.from(buf).toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

function sign(payload, secret) {
  const header = b64url(JSON.stringify({ alg: "HS256", typ: "JWT" }));
  const body = b64url(JSON.stringify(payload));
  const data = `${header}.${body}`;
  const sig = b64url(createHmac("sha256", secret).update(data).digest());
  return `${data}.${sig}`;
}

const secret = process.env.JWT_SECRET;
if (!secret || secret.length < 32) {
  console.error("JWT_SECRET must be set and at least 32 characters");
  process.exit(1);
}

const iat = Math.floor(Date.now() / 1000);
// Ten years. These are deployment-scoped service credentials, not user
// sessions - an expiry short enough to rotate is an expiry that will silently
// break the app on a Tuesday.
const exp = iat + 60 * 60 * 24 * 365 * 10;

const role = process.argv[2];
if (role !== "anon" && role !== "service_role") {
  console.error("usage: mint-keys.mjs <anon|service_role>");
  process.exit(1);
}

process.stdout.write(sign({ role, iss: "supabase", iat, exp }, secret));
