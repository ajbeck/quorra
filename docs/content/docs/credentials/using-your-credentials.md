---
title: "Using your credentials"
description: "Three ways a signed-in profile's temporary role credentials can reach your tools."
weight: 10
---
Once a profile is signed in, its temporary role credentials can reach your tools three ways. Most of the time you want the first one, because it needs no configuration at all.

{{< callout kind="note" >}}
Credentials are minted on demand and expire. Quorra shows the remaining time on the profile and renews them for you while the IAM Identity Center session is still valid.
{{< /callout >}}

## At the standard metadata address

Turn on the default endpoint and pick the profile it serves. It answers at `http://169.254.169.254`, the address the AWS SDKs already try. Nothing else to set — no `AWS_PROFILE`, no endpoint override.

```console
$ aws sts get-caller-identity
{ "Arn": "arn:aws:sts::111122223333:assumed-role/OrgAdmin/quorra" }
```

## At a custom endpoint

Additional endpoints listen on `127.0.0.1` with a port you choose. Point a compatible client at one when you want an explicit profile per shell.

{{< shells >}}
{{< shell name="bash" >}}
export AWS_EC2_METADATA_SERVICE_ENDPOINT=http://127.0.0.1:9678
{{< /shell >}}
{{< shell name="zsh" >}}
export AWS_EC2_METADATA_SERVICE_ENDPOINT=http://127.0.0.1:9678
{{< /shell >}}
{{< shell name="fish" >}}
set -gx AWS_EC2_METADATA_SERVICE_ENDPOINT http://127.0.0.1:9678
{{< /shell >}}
{{< shell name="powershell" >}}
$env:AWS_EC2_METADATA_SERVICE_ENDPOINT = "http://127.0.0.1:9678"
{{< /shell >}}
{{< /shells >}}

Quorra also publishes the active port at `~/Library/Application Support/Quorra/imds.port` for local scripts.

## As environment variables

Open a profile, choose your shell, and **Copy env** puts the exact export statements on the clipboard. Use this for a tool that reads credentials only from the environment.

| Variable                | What it holds                                  |
| ----------------------- | ---------------------------------------------- |
| `AWS_ACCESS_KEY_ID`     | The temporary access key for the assumed role. |
| `AWS_SECRET_ACCESS_KEY` | Its matching secret.                           |
| `AWS_SESSION_TOKEN`     | The session token that makes the pair valid.   |
| `AWS_REGION`            | The region the profile resolves to.            |

{{< callout kind="warn" >}}
Copied environment variables are a snapshot. They will not renew when Quorra renews the profile — the endpoints will.
{{< /callout >}}
