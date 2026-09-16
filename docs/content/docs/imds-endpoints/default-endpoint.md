---
title: "The default endpoint"
description: "Serve a signed-in profile at 169.254.169.254, the address the AWS SDKs already try."
weight: 10
---
The default endpoint answers at `http://169.254.169.254`, the address the AWS SDKs already try. Turn it on, pick a profile, and the normal IMDSv2 provider chain finds credentials with nothing else configured.

A narrowly scoped macOS Network Extension forwards only outbound TCP for `169.254.169.254:80` to Quorra's private `127.0.0.1:7114` backend. It relays opaque bytes and never interprets, stores or logs credentials. The app itself stays sandboxed.

## Before you start

- Quorra must be installed in `/Applications`. macOS will not approve the system extension anywhere else.
- At least one profile must be signed in, so the endpoint has credentials to serve.

## Turn it on

1. Select **Default IMDS Endpoint** in the sidebar and choose the profile it should serve.
2. Start it. The first time, macOS asks you to approve Quorra's system extension — allow it.
3. Open **System Settings → General → Login Items & Extensions**, click the info button beside Quorra's Network Extension under **Extensions**, and turn it on.

Quorra carries on starting the endpoint once macOS finishes. Both approvals persist across ordinary restarts and app launches.

{{< callout kind="note" >}}
Turning the endpoint off removes only its routing configuration. The approved system extension stays installed, so macOS does not have to approve it again next time.
{{< /callout >}}

## Check it is answering

```console
$ aws sts get-caller-identity
{ "Arn": "arn:aws:sts::111122223333:assumed-role/OrgAdmin/quorra" }
```

## If it will not connect

| What you see                         | What to do                                                                                                                   |
| ------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------- |
| Approval required                    | Use **Open Login Items & Extensions** and confirm the Network Extension is on. Check Quorra is running from `/Applications`. |
| macOS asks for a restart             | Restart before enabling the endpoint again.                                                                                  |
| Extension installed, still no answer | **Settings → IMDS → Recreate Routing Configuration…**, which replaces the saved configuration but keeps the approval.  |
| Sign-in needed                       | The served profile's session has expired. Sign in from the endpoint, the menu bar, or `quorra profiles sign-in`.             |

{{< callout kind="warn" >}}
Turn the default endpoint off before uninstalling Quorra, so its transparent proxy configuration is removed with it.
{{< /callout >}}
