# Lettertrace on Railway

Track how AI assistants answer questions about your brand: whether they name
you, who they name instead, and whether they cite your own pages. Upstream is
[letterstory/lettertrace](https://github.com/letterstory/lettertrace) (MIT).

**Deploy:** https://railway.com/deploy/lettertrace-aeo-monitor

## What you get

Two services and nothing to sign up for:

| Service | What it is |
|---|---|
| `postgres` | Railway's Postgres, on a volume. Everything you record lives here. |
| `lettertrace` | The app, plus the accounts service and data API it needs, behind one router. |

Upstream's own instructions ask you to create a Supabase project and paste
1,100 lines of SQL into it before the app will start. This image carries the
two pieces of Supabase that Lettertrace actually uses, so there is nothing to
set up outside Railway.

## First run

1. Click deploy. First boot takes about two minutes: the app creates its
   database roles, migrates the accounts tables, and applies its own schema
   before it starts serving.
2. Open the public URL and create an account. **The first person to sign up is
   not special.** Signups are open by default, so if the URL is shared, close
   them (below).
3. Go to **Settings** and paste an AI provider key: Anthropic, OpenAI, Google or
   Perplexity. It is checked against the provider before it is saved, and stored
   encrypted. Nothing runs until you add one, and every call it makes is billed
   to that key, not to Railway.
4. Fill in your brand name, any aliases, and your domain.
5. Add competitors, add a topic, click **Generate variations**, then **Run
   monitor now**.

A run costs real money on your provider account. A small first run (one topic,
a handful of prompts, one model) is cents. Prompts times replicates times models
is the multiplier to watch.

## Close signups once you are in

Nothing stops a second person from creating an account on your deployment. On
the `lettertrace` service, add:

```
DISABLE_SIGNUP=true
```

Existing accounts keep working. You can flip it back to add someone.

## Scheduled monitoring

Set a project's schedule to Daily or Weekly in Settings, then point any
scheduler at the run endpoint. `CRON_SECRET` is already generated for you; copy
it from the service variables.

```bash
curl -X POST https://your-app.up.railway.app/api/cron/run \
  -H "Authorization: Bearer $CRON_SECRET"
```

A Railway cron service, GitHub Actions, or a laptop crontab all work. Without
the header the endpoint refuses the request, which is deliberate: it is the only
thing between the internet and your provider spend.

Scheduled runs use each account owner's own key and skip anyone who has not
added one.

## Optional extras

Add these on the `lettertrace` service when you want them. All are off by
default.

| Variable | What it turns on |
|---|---|
| `DISABLE_SIGNUP=true` | No new accounts. |
| `MAILER_AUTOCONFIRM=false` | Require email confirmation. Only useful with mail configured. |
| `ADMIN_USER_IDS` | Opens the `/admin` operations screen for those account ids. Empty means it 404s for everyone, including you. |
| `ADMIN_ALERT_EMAIL` + `RESEND_API_KEY` | Emails you when someone signs up. |
| `OPS_TELEMETRY=1` | Records run outcomes and errors into your own database. Off means nothing is recorded. |
| `TRIAL_ANTHROPIC_API_KEY` etc. | Lets new accounts run a few monitors on YOUR key before adding their own. Leave unset unless you know why you want it. |
| `ENCRYPTION_KEY` | Only if you are moving an existing Lettertrace database across. Overrides the derived key so your stored provider keys still decrypt. |

## The two secrets that matter

`JWT_SECRET` and `ENCRYPTION_SECRET` are generated for you at deploy time.

- Changing **`JWT_SECRET`** signs everyone out and invalidates any API tokens.
  No data is lost.
- Changing **`ENCRYPTION_SECRET`** makes every stored AI provider key
  permanently unreadable. Everyone has to paste their keys in again. There is no
  recovery, so leave it alone.

## Programmatic access

The app exposes a REST API and an MCP server, both authenticated with a key you
create in **Settings → API & MCP access**. To point Claude at your data:

```bash
claude mcp add --transport http lettertrace https://your-app.up.railway.app/api/mcp/mcp \
  -H "Authorization: Bearer lt_live_..."
```

## Troubleshooting

**Stuck on "Deploying" for the first two minutes.** Expected. The container
waits for Postgres, then runs three sets of migrations before it serves
anything. The deploy logs narrate each step.

**The healthcheck never goes green and the logs say the database never became
reachable.** The `lettertrace` service's `DATABASE_URL` is not pointing at the
Postgres service. On a template deploy this is wired for you; if you renamed the
Postgres service, the reference broke.

**Signed in, but the dashboard is empty and nothing errors.** This is what a
broken access-rules setup looks like. Redeploy the `lettertrace` service; the
boot sequence repairs the helper functions the access rules depend on. Report it
if it survives a redeploy.

**Saving a provider key fails with a message about the deployment being
misconfigured.** `ENCRYPTION_SECRET` is missing. It is generated at deploy time,
so this only happens if it was deleted.

## Scaling and limits

- One app container. Runs execute inside the request that starts them, so a
  large prompt set is a long request. Use the background option on the API, or
  raise the service's resources.
- Postgres is a single instance on a volume. Take backups from the Railway
  dashboard if the history matters to you.
- The accounts service sends no email in this configuration, which is why
  confirmation is off. Password reset by email needs mail configured upstream.

## What is deliberately not here

- **Supabase Storage and Realtime.** The app never calls them.
- **Social sign-in.** Google and GitHub buttons need OAuth apps registered
  against an external identity service; email and password works out of the box.
- **The visitor de-anonymisation pixel** upstream runs on its own marketing
  site. Unset here, as upstream intends for self-hosters.

## Repository layout

```
image/          the container: upstream's app plus the accounts service,
                data API, router, and the boot sequence that wires them
test/           contract tests that boot the image against a throwaway
                Postgres and drive signup, reads, writes and access rules
template.json   the build sheet: every service, variable and why it is set
build_source.py builds the live source project the template is generated from
```
