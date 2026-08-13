#!/usr/bin/env python3
"""Builds the live source project in Auromations, which is what gets generated
into the template.

Literal values rather than cross-service references: a
${{other.RAILWAY_PUBLIC_DOMAIN}} resolves to an empty string in a live project
and only fills in during a template deploy, so a source project wired with
references looks fine and boots broken. References go back in during the
template repair, where they belong.
"""

import pathlib
import secrets
import string
import sys

sys.path.insert(0, str(pathlib.Path("~/.claude/skills/create-template-for-railway/scripts").expanduser()))
import rw  # noqa: E402

WORKSPACE = "fc4796db-2c6c-4354-a564-d4a1d900af53"  # Auromations
IMAGE = "ghcr.io/hmseeb/lettertrace-railway:0.1.0-r2"
PG_IMAGE = "ghcr.io/railwayapp-templates/postgres-ssl:17"


def rand(n=48):
    alphabet = string.ascii_letters + string.digits
    return "".join(secrets.choice(alphabet) for _ in range(n))


def q(doc, variables=None, internal=False):
    return rw.gql(doc, variables, internal=internal)


def main():
    project = q(
        """mutation($input: ProjectCreateInput!) {
             projectCreate(input: $input) {
               id
               environments { edges { node { id name } } }
             }
           }""",
        {"input": {"name": "lettertrace-source", "workspaceId": WORKSPACE}},
    )["projectCreate"]
    project_id = project["id"]
    env_id = next(
        e["node"]["id"] for e in project["environments"]["edges"] if e["node"]["name"] == "production"
    )
    print(f"project {project_id}  env {env_id}")

    pg_password = rand(32)
    database_url = f"postgresql://postgres:{pg_password}@postgres.railway.internal:5432/railway"

    def service(name, image, variables, healthcheck=None):
        svc = q(
            """mutation($input: ServiceCreateInput!) {
                 serviceCreate(input: $input) { id name }
               }""",
            {
                "input": {
                    "projectId": project_id,
                    "environmentId": env_id,
                    "name": name,
                    "source": {"image": image},
                    "variables": variables,
                }
            },
        )["serviceCreate"]
        print(f"  service {name} {svc['id']}")

        update = {"restartPolicyType": "ON_FAILURE"}
        if healthcheck:
            update["healthcheckPath"] = healthcheck
        q(
            """mutation($serviceId: String!, $environmentId: String!, $input: ServiceInstanceUpdateInput!) {
                 serviceInstanceUpdate(serviceId: $serviceId, environmentId: $environmentId, input: $input)
               }""",
            {"serviceId": svc["id"], "environmentId": env_id, "input": update},
        )
        return svc["id"]

    postgres = service(
        "postgres",
        PG_IMAGE,
        {
            # A subdirectory of the mount, not the mount itself: Railway volumes
            # ship with a lost+found and initdb refuses a non-empty directory.
            "PGDATA": "/var/lib/postgresql/data/pgdata",
            "POSTGRES_USER": "postgres",
            "POSTGRES_PASSWORD": pg_password,
            "POSTGRES_DB": "railway",
            "SSL_CERT_DAYS": "820",
            "RAILWAY_DEPLOYMENT_DRAINING_SECONDS": "60",
        },
    )
    q(
        """mutation($input: VolumeCreateInput!) { volumeCreate(input: $input) { id } }""",
        {
            "input": {
                "projectId": project_id,
                "environmentId": env_id,
                "serviceId": postgres,
                "mountPath": "/var/lib/postgresql/data",
            }
        },
    )

    # No start command anywhere in this project. Railway execs one raw and
    # discards the image entrypoint, which is where the entire boot sequence -
    # database roles, auth migrations, app schema - lives.
    app = service(
        "lettertrace",
        IMAGE,
        {
            "PORT": "8080",
            "DATABASE_URL": database_url,
            "JWT_SECRET": rand(64),
            "ENCRYPTION_SECRET": rand(64),
            "CRON_SECRET": rand(64),
        },
        healthcheck="/login",
    )
    domain = q(
        """mutation($input: ServiceDomainCreateInput!) {
             serviceDomainCreate(input: $input) { domain }
           }""",
        {"input": {"environmentId": env_id, "serviceId": app, "targetPort": 8080}},
    )["serviceDomainCreate"]["domain"]
    print(f"  origin https://{domain}")

    # The service was created before its domain existed, so its first boot has
    # no public hostname to derive the browser-facing origin from. A genuinely
    # fresh deploy (NOT a redeploy, which replays the old config snapshot)
    # picks it up.
    q(
        """mutation($serviceId: String!, $environmentId: String!) {
             serviceInstanceDeployV2(serviceId: $serviceId, environmentId: $environmentId)
           }""",
        {"serviceId": app, "environmentId": env_id},
    )

    print()
    print(f"PROJECT={project_id}")
    print(f"ENV={env_id}")
    print(f"PG={postgres}")
    print(f"APP={app}")
    print(f"ORIGIN=https://{domain}")


if __name__ == "__main__":
    main()
