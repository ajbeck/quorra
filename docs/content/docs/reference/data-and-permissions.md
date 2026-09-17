---
title: "Data and permissions"
description: "What Quorra asks macOS for, what it stores, and where."
weight: 20
---
Quorra asks macOS for two approvals and one folder. Nothing else.

## What crosses which boundary

| Surface           | What Quorra uses it for                                                        | Scope                                    |
| ----------------- | ------------------------------------------------------------------------------ | ---------------------------------------- |
| Your AWS folder   | Imports sessions and profiles once; writes them back only if you enable export | One folder you pick, normally `~/.aws`   |
| Network Extension | Forwards outbound TCP for the metadata address to Quorra's local backend       | `169.254.169.254:80` only                |
| macOS Keychain    | Stores Identity Center tokens and temporary role credentials                   | Never in Quorra's own files              |
| Local endpoints   | Serve a chosen profile to tools                                                | Bound to `127.0.0.1`, never your network |
| The app itself    | —                                                                            | Sandboxed for the whole of its life      |

## Credentials

Identity Center access tokens and temporary role credentials are stored in the macOS Keychain. They are not written into Quorra's application files, and they are minted on demand rather than held indefinitely.

## Your AWS files

With **Export to AWS folder** off, Quorra never writes to the files you selected.

With it on, Quorra updates only the `sso-session` and `profile` sections it manages, and keeps your other sections, keys and comments as they are.

## The network

IMDS backends bind to `127.0.0.1` and are not reachable from your local network. The default endpoint is reachable only through the exact `169.254.169.254:80` Network Extension rule.

{{< callout kind="note" >}}
The Network Extension relays opaque bytes. It never interprets, stores or logs credentials or tokens, and it sees nothing else on your network.
{{< /callout >}}
