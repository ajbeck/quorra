---
title: "Add a profile"
description: "Pick an account and role from the Identity Center portal, and Quorra builds the profile for you."
weight: 20
---
A profile is one role in one account, reached through an Identity Center session. Quorra needs the session signed in before it can offer you anything to pick from.

## From the portal

Choose **+** under the profile list and pick the session. Quorra asks Identity Center which accounts and roles you can reach, and offers them as a picker rather than asking you to type account numbers.

The profile is named `session:account:role` by default. Rename it to anything you like — the name is what you will see in the sidebar, in the endpoint's profile picker, and in `AWS_PROFILE` if you export.

## The session badge

Each profile row carries a coloured badge naming the session it belongs to. The colour is derived from the session name and is stable across launches, so the same organisation always looks the same.

The colour means _which organisation_, never a status. Profiles not backed by a session carry no colour.

{{< callout kind="note" >}}
A profile that is not linked to a session cannot serve credentials. Quorra says so on the profile, and the fix is to delete it and add it again under a session.
{{< /callout >}}

## Editing

**Edit** opens the profile for changes. Quorra holds your edits as a draft until you **Save** or **Discard**, so a half-finished change never reaches your AWS folder — and, with export on, the write happens on save.

## From the command line

```console
$ quorra profiles list
NAME                   SESSION       REGION     ACCOUNT       ROLE
ac:cp:org_admin        astrocompute  us-east-2  111122223333  OrgAdmin
ac:mgmt:admin          astrocompute  us-east-2  444455556666  Admin
```

`--format names` prints just the names, one per line, which is the one to pipe into another command. `--format json` gives you the whole record.
