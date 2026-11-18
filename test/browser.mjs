// The part curl cannot prove: that a real browser can sign up, get a session
// cookie, and land on a dashboard that renders.
//
// Everything between the sign-in form and the dashboard runs in places curl
// never touches - supabase-js writing the session cookie, the middleware
// refreshing it on the next request, and server components reading it and then
// calling the data API from INSIDE the container over the deployment's own
// public origin. Each of those has its own way of failing while every API check
// stays green.
//
// Usage:  node test/browser.mjs https://your-app.up.railway.app
import { chromium } from "playwright";

const base = (process.argv[2] || "").replace(/\/$/, "");
if (!base) {
  console.error("usage: node test/browser.mjs <origin>");
  process.exit(1);
}

const email = `browser-${Date.now()}@example.com`;
const password = "browser-verification-password-123";

let pass = 0;
let fail = 0;
const ok = (m) => { console.log(`  PASS  ${m}`); pass++; };
const bad = (m, d) => { console.log(`  FAIL  ${m}`); if (d) console.log(`        ${d}`); fail++; };

const browser = await chromium.launch();
const page = await browser.newPage();

const consoleErrors = [];
page.on("console", (m) => { if (m.type() === "error") consoleErrors.push(m.text()); });
const failedRequests = [];
page.on("response", (r) => {
  if (r.status() >= 500) failedRequests.push(`${r.status()} ${r.url()}`);
});

try {
  console.log(`== ${base} ==`);

  await page.goto(`${base}/login`, { waitUntil: "networkidle" });
  ok("the sign-in page loads in a browser");

  // The page opens in sign-in mode; "Create one" is the toggle to sign-up.
  await page.getByRole("button", { name: "Create one" }).click();
  await page.fill("#email", email);
  await page.fill("#password", password);
  await page.click('button[type="submit"]');

  await page.waitForURL(/\/dashboard/, { timeout: 60_000 });
  ok(`signing up lands on ${new URL(page.url()).pathname}`);

  // A session that only exists in memory would evaporate here. This asserts the
  // cookie was written and that the server accepts it on a fresh navigation.
  const landed = page.url();
  await page.goto(landed, { waitUntil: "networkidle" });
  if (/\/login/.test(page.url())) {
    bad("the session survives a reload", `bounced back to ${page.url()}`);
  } else {
    ok("the session survives a reload");
  }

  // The sidebar is rendered on the server from the account's own data, so its
  // presence is proof the server side read the session and reached the data
  // API from inside the container.
  const nav = await page.getByRole("link", { name: "Competitors" }).count();
  nav ? ok("the signed-in dashboard renders its navigation")
      : bad("the signed-in dashboard renders its navigation");

  // Upstream #169 turned the form into a URL-first flow; accept either copy.
  const wizard = await page.getByText(/what.s your website|set up your brand/i).count();
  wizard ? ok("a brand new account is shown the setup wizard")
         : bad("a brand new account is shown the setup wizard");

  // Settings is where the deployer pastes their AI provider key, so it has to
  // be reachable and it has to render.
  await page.goto(`${base}/dashboard/settings`, { waitUntil: "networkidle" });
  if (/\/login/.test(page.url())) {
    bad("settings is reachable while signed in", `bounced to ${page.url()}`);
  } else {
    const hasKeyField = await page
      .getByText(/anthropic|openai|api key/i)
      .first()
      .count();
    hasKeyField
      ? ok("the provider key form is on the settings page")
      : bad("the provider key form is on the settings page");
  }

  failedRequests.length === 0
    ? ok("no request returned a server error")
    : bad("no request returned a server error", failedRequests.slice(0, 3).join(" | "));

  // Noisy warnings are normal; a crash in the page is not.
  const real = consoleErrors.filter((e) => !/favicon|Download the React/i.test(e));
  real.length === 0
    ? ok("no errors in the browser console")
    : bad("no errors in the browser console", real.slice(0, 3).join(" | "));
} catch (err) {
  bad("the browser journey completed", String(err).split("\n")[0]);
  await page.screenshot({ path: "/tmp/lettertrace-browser-failure.png" }).catch(() => {});
  console.log(`        screenshot: /tmp/lettertrace-browser-failure.png`);
  console.log(`        url at failure: ${page.url()}`);
} finally {
  await browser.close();
}

console.log(`\n== ${pass} passed, ${fail} failed ==`);
process.exit(fail === 0 ? 0 : 1);
