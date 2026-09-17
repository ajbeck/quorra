---
title: "Additional endpoints"
description: "Extra listeners on 127.0.0.1 for tools that take a custom metadata URL."
weight: 20
---
The default endpoint answers at the standard address, which suits most tools. Additional endpoints listen on `127.0.0.1` with a port you choose, for the cases the standard address cannot cover:

- a tool that takes a custom metadata URL and you would rather be explicit
- two shells that need different profiles at the same time
- testing against a specific IMDS version or hop limit

## Create one

Choose **+** under the endpoint list. You give it a name, a port, and the profile it serves.

| Setting      | What it does                                                    |
| ------------ | --------------------------------------------------------------- |
| Port         | The port on `127.0.0.1` to listen on                            |
| Bind address | Always `127.0.0.1`. Endpoints are never exposed on your network |
| IMDS version | `v1`, `v2`, or `v1 + v2`                                        |
| Hop limit    | The IMDSv2 response hop limit                                   |

## Point a tool at it

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

The endpoint detail can copy that line for you, along with the plain URL and a `curl` that exercises it.

{{< callout kind="note" >}}
Additional endpoints need no macOS approval. Only the default endpoint does, because only it claims the `169.254.169.254` address.
{{< /callout >}}

## Watching it work

A running endpoint shows its state, how long it has been up, how many requests it has served and which IMDS versions it answers — which is usually the quickest way to tell whether a tool is actually reaching it.

Quorra also publishes the active port at `~/Library/Application Support/Quorra/imds.port` for local scripts.
