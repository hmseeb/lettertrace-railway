#!/usr/bin/env python3
"""Publishes the template to the marketplace.

The slug is minted from the name here and never follows a later rename, so the
name is effectively permanent. Republishing an already-published template mints
an ugly suffixed slug, which is why this runs exactly once.
"""

import pathlib
import sys

sys.path.insert(0, str(pathlib.Path("~/.claude/skills/create-template-for-railway/scripts").expanduser()))
import rw  # noqa: E402

TEMPLATE_ID = "8da5d0f3-dacd-4481-8289-b984a745986e"
WORKSPACE = "fc4796db-2c6c-4354-a564-d4a1d900af53"  # Auromations

# 75 characters is the hard limit and Railway truncates silently past it. This
# is the field marketplace search actually reads, so the keywords live here
# rather than in the name, where they would only cost a worse permanent URL.
DESCRIPTION = "AEO and GEO monitoring: how ChatGPT, Claude and Perplexity name your brand"

README = (pathlib.Path(__file__).parent / "TEMPLATE_OVERVIEW.md").read_text()

assert len(DESCRIPTION) <= 75, len(DESCRIPTION)

published = rw.gql(
    """mutation($id: String!, $input: TemplatePublishInput!) {
         templatePublish(id: $id, input: $input) { id code isApproved }
       }""",
    {
        "id": TEMPLATE_ID,
        "input": {
            "category": "Analytics",
            "description": DESCRIPTION,
            "readme": README,
            "workspaceId": WORKSPACE,
        },
    },
)["templatePublish"]

print(published)
print(f"https://railway.com/deploy/{published['code']}")
