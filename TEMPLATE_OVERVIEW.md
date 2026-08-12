# Deploy and Host Lettertrace on Railway

Lettertrace watches how AI assistants answer questions about your brand. You
describe your brand and a few topics, it generates the questions people actually
ask, runs them against ChatGPT, Claude, Gemini or Perplexity using your own API
key, and records who got named, who got recommended, and which pages got cited.
Over time that becomes a trend line for your visibility and your share of voice
against named competitors.

## About Hosting Lettertrace

Lettertrace is a Next.js app that normally expects a hosted Supabase project for
its database and accounts, which means creating an account somewhere else and
pasting over a thousand lines of SQL before the app will start. This template
removes that step. The container carries the two pieces it actually uses, the
accounts service and the data API, alongside the app itself behind a single
router, with Railway's own Postgres holding the data on a volume.

On first boot the container creates its database roles, migrates the accounts
tables, applies the application schema, and only then starts serving. That takes
about two minutes and the deploy logs narrate each step. Nothing is asked of you
at deploy time: the signing secret, the at-rest encryption secret and the
scheduled-run secret are all generated for you.

It is bring your own key by design. No AI provider credentials ship with the
image and none are asked for at deploy time. You add a key inside the app after
signing in, where it is verified against the provider and then encrypted before
it is stored. Every model call your deployment makes is billed to that key.

## Common Use Cases

- Watching whether AI assistants name your product when someone asks for a
  recommendation in your category, and how that changes as you publish.
- Benchmarking share of voice against a named list of competitors, including
  finding competitors your own stored answers already mention that you were not
  tracking.
- Checking whether the models are reading your own pages. Citations usually move
  before mentions do, which makes them the only early signal a young brand has.
- Feeding the results into an agent or a script through the REST API or the
  built in MCP server, so a Claude session can ask about your visibility
  directly.

## Dependencies for Lettertrace Hosting

- A Postgres database, included in this template as a Railway service with a
  volume.
- An API key from at least one AI provider, added inside the app after you sign
  in. Anthropic, OpenAI, Google and Perplexity are supported, as is a single
  router key that covers several of them.

### Deployment Dependencies

- Upstream project: https://github.com/letterstory/lettertrace (MIT)
- Container image: https://github.com/hmseeb/lettertrace-railway
- Anthropic, OpenAI, Google AI or Perplexity account, for the key you add after
  deploying

### Implementation Details

**First run.** Open the public URL and create an account. Signups are open by
default and the first account is not privileged, so if the address is shared,
close signups by adding `DISABLE_SIGNUP=true` to the lettertrace service.
Existing accounts keep working.

**Adding your provider key.** Settings is where it goes. The key is checked
against the provider before it is saved, so a typo is refused immediately rather
than at the end of a run. Nothing runs until a key is present.

**What a run costs.** Prompts times replicates times models, on your provider
account. A first run with one topic, a handful of prompts and one model is
cents. The replicates setting exists because answers vary between identical
calls, and raising it narrows the confidence interval at a linear cost.

**Scheduled monitoring.** Set a schedule in Settings, then point any scheduler at
the run endpoint. `CRON_SECRET` is already generated; copy it from the service
variables.

```
curl -X POST https://your-app.up.railway.app/api/cron/run \
  -H "Authorization: Bearer $CRON_SECRET"
```

Without that header the endpoint refuses the request, which is deliberate. It is
the only thing standing between the internet and your provider spend.

**The two secrets that matter.** Changing `JWT_SECRET` signs everyone out and
loses no data. Changing `ENCRYPTION_SECRET` makes every stored provider key
permanently unreadable, with no recovery, so leave it alone.

**Optional extras**, all off by default, set on the lettertrace service:

| Variable | Effect |
|---|---|
| `DISABLE_SIGNUP=true` | No new accounts |
| `ADMIN_USER_IDS` | Opens the operations screen for those accounts. Empty means it is hidden from everyone, including you |
| `ADMIN_ALERT_EMAIL` plus `RESEND_API_KEY` | Emails you when someone signs up |
| `OPS_TELEMETRY=1` | Records run outcomes into your own database. Off records nothing |
| `ENCRYPTION_KEY` | Only when migrating an existing Lettertrace database in, so stored keys still decrypt |

**Troubleshooting.** A first boot that sits in Deploying for two minutes is
expected. If the logs say the database never became reachable, the lettertrace
service's `DATABASE_URL` is not pointing at the Postgres service, which happens
if the Postgres service was renamed. If you are signed in but the dashboard is
empty with no error anywhere, redeploy the lettertrace service: its boot
sequence repairs the helper functions the access rules depend on.

**Scaling.** One app container, and runs execute inside the request that starts
them, so a large prompt set is a long request. Use the background option on the
API for those, or give the service more resources. Postgres is a single instance
on a volume, so take backups from the Railway dashboard if the history matters.

**Deliberately not included.** Supabase Storage and Realtime, because the app
never calls them. Social sign in, because it needs OAuth apps registered against
an external identity service, while email and password works immediately. The
third party visitor tracking pixel upstream runs on its own marketing site,
which upstream also leaves unset for self hosters.

## Why Deploy Lettertrace on Railway?

Railway is a singular platform to deploy your infrastructure stack. Railway will
host your infrastructure so you don't have to deal with configuration, while
allowing you to vertically and horizontally scale it.

By deploying Lettertrace on Railway, you are one step closer to supporting a
complete full stack application with minimal burden. Host your servers,
databases, AI agents, and more on Railway.

For Lettertrace specifically, Railway removes the one thing that makes it
awkward to self host. The app assumes a managed database and accounts service
sitting outside it, and this template supplies both inside the deployment, with
Postgres as a first class Railway service on a volume. The result is a
monitoring tool that starts working the moment it finishes deploying, with your
provider keys and your competitive data staying in infrastructure you control.
