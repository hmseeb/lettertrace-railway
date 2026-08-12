#!/usr/bin/env python3
"""Clicks the deploy button the way a stranger would: no projectId, so Railway
makes a fresh project. Nothing is prompted for in this template, so the config
goes through untouched, which is exactly what the button does."""

import json
import pathlib
import sys
import time

sys.path.insert(0, str(pathlib.Path("~/.claude/skills/create-template-for-railway/scripts").expanduser()))
import rw  # noqa: E402

TEMPLATE_ID = "8da5d0f3-dacd-4481-8289-b984a745986e"
WORKSPACE_ID = "fc4796db-2c6c-4354-a564-d4a1d900af53"

config = rw.gql(
    "query($id: String!) { template(id: $id) { serializedConfig } }",
    {"id": TEMPLATE_ID},
)["template"]["serializedConfig"]

result = rw.gql(
    """mutation($input: TemplateDeployV2Input!) {
         templateDeployV2(input: $input) { projectId workflowId }
       }""",
    {"input": {"templateId": TEMPLATE_ID, "workspaceId": WORKSPACE_ID, "serializedConfig": config}},
)["templateDeployV2"]
project_id = result["projectId"]
print("fresh project:", project_id)

states = []
for _ in range(60):
    time.sleep(10)
    project = rw.gql(
        """query($id: String!) {
             project(id: $id) {
               name
               environments { edges { node { id name } } }
               services { edges { node {
                 id name
                 serviceInstances { edges { node {
                   latestDeployment { id status }
                   domains { serviceDomains { domain } }
                 } } }
               } } }
             }
           }""",
        {"id": project_id},
    )["project"]
    states = []
    for edge in project["services"]["edges"]:
        node = edge["node"]
        for inst in node["serviceInstances"]["edges"]:
            dep = inst["node"]["latestDeployment"]
            states.append(
                (
                    node["name"],
                    dep["status"] if dep else "none",
                    [d["domain"] for d in inst["node"]["domains"]["serviceDomains"]],
                )
            )
    print("  ", states)
    if states and all(s[1] in ("SUCCESS", "FAILED", "CRASHED") for s in states):
        break

print(
    json.dumps(
        {
            "projectId": project_id,
            "environmentId": project["environments"]["edges"][0]["node"]["id"],
            "states": states,
        },
        indent=2,
    )
)
