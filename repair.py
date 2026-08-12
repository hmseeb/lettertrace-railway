#!/usr/bin/env python3
"""Puts back everything templateGenerate strips.

Generation drops every literal variable value as an anti-secret measure, so what
comes out is the right shape with nothing in it: a deployer would be asked for
eleven values, none of which they could sensibly answer.

This writes the real config through templateUpsertConfig on the internal
endpoint, which is the composer's own Save button, then reads it back and checks
it field by field. All four input fields are required or it fails with a generic
error.

What templateGenerate hands back cannot be edited: passing its id to
templateUpsertConfig returns "Not Authorized", while the identical call against
a template this script created succeeds. So generation is treated as a read: its
config is copied into a fresh template, with a fresh UUID for the template and
for every service and volume inside it, because the server rejects reused ones
as an ID collision. Pass `new` as the id the first time and the id it prints
thereafter.

Usage: repair.py <templateId|new> <path-to-generated.json>
"""

import json
import pathlib
import re
import sys
import uuid

sys.path.insert(0, str(pathlib.Path("~/.claude/skills/create-template-for-railway/scripts").expanduser()))
import rw  # noqa: E402

WORKSPACE = "fc4796db-2c6c-4354-a564-d4a1d900af53"  # Auromations
NAME = "Lettertrace AEO Monitor"

# Pinned to the commit the image is built from, so upstream moving the file
# cannot break the listing later. Orange and mint marks on black, which reads
# on Railway's dark canvas.
ICON = (
    "https://raw.githubusercontent.com/letterstory/lettertrace/"
    "061bb2d8a027f76e4b51a0969f4c9ca8628bad84/public/icon.png"
)

JWT_HELP = (
    "Signs everyone's sessions, and the key the browser uses is derived from it. "
    "Generated for you. Changing it signs everybody out; it loses no data."
)
ENCRYPTION_HELP = (
    "Encrypts the AI provider keys people add inside the app. Generated for you. "
    "Changing it makes every stored provider key permanently unreadable, so leave "
    "it alone."
)
CRON_HELP = (
    "Required in the Authorization header to trigger a scheduled run. Generated "
    "whether or not you wire up a scheduler, because that endpoint spends your AI "
    "provider credit and this is the only thing guarding it."
)

VARIABLES = {
    # Railway's own Postgres config, copied from template(code:"postgres").
    # DATABASE_URL lives here so the app can reference it by name rather than
    # carry its own copy of the password.
    "postgres": {
        "PGDATA": {
            "isOptional": False,
            "description": "Where the database is initialized. A subdirectory of the mount, because a volume root is never empty and initdb refuses a non-empty directory.",
            "defaultValue": "/var/lib/postgresql/data/pgdata",
        },
        "PGHOST": {"isOptional": False, "defaultValue": "${{RAILWAY_PRIVATE_DOMAIN}}"},
        "PGPORT": {"isOptional": False, "defaultValue": "5432"},
        "PGUSER": {"isOptional": False, "defaultValue": "${{POSTGRES_USER}}"},
        "PGDATABASE": {"isOptional": False, "defaultValue": "${{POSTGRES_DB}}"},
        "PGPASSWORD": {"isOptional": False, "defaultValue": "${{POSTGRES_PASSWORD}}"},
        "POSTGRES_DB": {"isOptional": False, "defaultValue": "railway"},
        "POSTGRES_USER": {"isOptional": False, "defaultValue": "postgres"},
        "POSTGRES_PASSWORD": {
            "isOptional": False,
            "defaultValue": '${{ secret(32, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ") }}',
        },
        "DATABASE_URL": {
            "isOptional": False,
            "defaultValue": "postgresql://${{PGUSER}}:${{POSTGRES_PASSWORD}}@${{RAILWAY_PRIVATE_DOMAIN}}:5432/${{PGDATABASE}}",
        },
        "SSL_CERT_DAYS": {"isOptional": True, "defaultValue": "820"},
        "RAILWAY_DEPLOYMENT_DRAINING_SECONDS": {
            "isOptional": False,
            "description": "Lets Postgres shut down cleanly",
            "defaultValue": "60",
        },
    },
    "lettertrace": {
        "PORT": {
            "isOptional": False,
            "description": "Port the app is served on. Pinned, because Next.js honours PORT and would otherwise drift off the port the public address points at.",
            "defaultValue": "8080",
        },
        # Name-based, never a service UUID: a UUID-keyed reference resolves to an
        # empty string after any config regeneration while the deploy still
        # reports success.
        "DATABASE_URL": {
            "isOptional": False,
            "description": "Where everything is stored. Wired to the Postgres service in this template.",
            "defaultValue": "${{postgres.DATABASE_URL}}",
        },
        "JWT_SECRET": {"isOptional": False, "description": JWT_HELP, "defaultValue": "${{secret(64)}}"},
        "ENCRYPTION_SECRET": {"isOptional": False, "description": ENCRYPTION_HELP, "defaultValue": "${{secret(64)}}"},
        "CRON_SECRET": {"isOptional": False, "description": CRON_HELP, "defaultValue": "${{secret(64)}}"},
    },
}

ICONS = {
    "postgres": "https://devicons.railway.app/i/postgresql.svg",
    "lettertrace": ICON,
}


def main():
    template_id = sys.argv[1]
    config = json.loads(pathlib.Path(sys.argv[2]).read_text())
    if "templateGenerate" in config:
        config = config["templateGenerate"]["serializedConfig"]

    if template_id == "new":
        template_id = str(uuid.uuid4())
        remap = {sid: str(uuid.uuid4()) for sid in config["services"]}
        rebuilt = {"buckets": config.get("buckets", {}), "services": {}}
        for sid, svc in config["services"].items():
            svc = json.loads(json.dumps(svc))
            if "volumeMounts" in svc and svc["volumeMounts"]:
                # Keyed by the owning service's id, so it has to move with it.
                svc["volumeMounts"] = {remap[k]: v for k, v in svc["volumeMounts"].items()}
            rebuilt["services"][remap[sid]] = svc
        config = rebuilt
        print("minting template", template_id)

    for service in config["services"].values():
        name = service["name"]
        service["variables"] = VARIABLES[name]
        service["icon"] = ICONS[name]

    saved = rw.gql(
        """mutation($id: String!, $input: TemplateUpsertConfigInput!) {
             templateUpsertConfig(id: $id, input: $input) { id code }
           }""",
        {
            "id": template_id,
            "input": {
                "name": NAME,
                "workspaceId": WORKSPACE,
                "serializedConfig": config,
                "canvasConfig": {},
            },
        },
        internal=True,
    )["templateUpsertConfig"]
    print(f"saved  id {saved['id']}  code {saved['code']}")

    # Read it back. A write that returned success is not a write that landed,
    # and a reference keyed by UUID instead of by name resolves to an empty
    # string on every deploy while still reporting SUCCESS.
    back = rw.gql(
        "query($c: String!) { template(code: $c) { serializedConfig } }",
        {"c": saved["code"]},
    )["template"]["serializedConfig"]

    problems = []
    for service in back["services"].values():
        name = service["name"]
        want = VARIABLES[name]
        got = service.get("variables", {})
        for key, spec in want.items():
            if key not in got:
                problems.append(f"{name}.{key} missing")
                continue
            if got[key].get("defaultValue") != spec.get("defaultValue"):
                problems.append(
                    f"{name}.{key} default is {got[key].get('defaultValue')!r}, wanted {spec.get('defaultValue')!r}"
                )
        if service.get("icon") != ICONS[name]:
            problems.append(f"{name}.icon is {service.get('icon')!r}")

    app = next(s for s in back["services"].values() if s["name"] == "lettertrace")
    if app.get("deploy", {}).get("healthcheckPath") != "/login":
        problems.append(f"healthcheck is {app.get('deploy', {}).get('healthcheckPath')!r}")
    if app.get("deploy", {}).get("startCommand"):
        # A start command would replace the image entrypoint, which is the whole
        # boot sequence: database roles, auth migrations, app schema.
        problems.append(f"a start command crept in: {app['deploy']['startCommand']!r}")
    ports = [d.get("port") for d in app.get("networking", {}).get("serviceDomains", {}).values()]
    if ports != [8080]:
        problems.append(f"public address target port is {ports}, wanted [8080]")

    pg = next(s for s in back["services"].values() if s["name"] == "postgres")
    if not pg.get("volumeMounts"):
        problems.append("postgres lost its volume")

    # UUIDs inside a reference are the failure that looks exactly like a race.
    blob = json.dumps(back)
    for ref in re.findall(r"\$\{\{[^}]*\}\}", blob):
        if re.search(r"[0-9a-f]{8}-[0-9a-f]{4}-", ref):
            problems.append(f"reference keyed by UUID: {ref}")

    for line in problems:
        print("MISMATCH", line)
    print("clean" if not problems else f"{len(problems)} problems")
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
