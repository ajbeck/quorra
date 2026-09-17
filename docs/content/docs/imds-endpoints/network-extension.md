---
title: "The Network Extension"
description: "What macOS is approving when you enable the default endpoint, and how to repair it."
weight: 30
---
Only the default endpoint needs this. It claims `169.254.169.254`, an address your Mac does not otherwise route anywhere, and reaching it takes a system extension.

## What it actually does

Quorra installs a narrowly scoped macOS Network Extension. It forwards outbound TCP for exactly one destination — `169.254.169.254:80` — to Quorra's private backend on `127.0.0.1:7114`.

It relays opaque bytes. It does not interpret, store or log what passes through it, and it sees nothing else on your network. Quorra itself stays in the macOS sandbox throughout.

## Two approvals, once

macOS asks separately to install the system extension and to activate its network functionality. Both persist across ordinary endpoint restarts and app launches.

You will be asked again if the extension is updated, or if you reset your system network settings.

{{< callout kind="note" >}}
Turning the default endpoint off removes only its routing configuration. The approved system extension stays installed, which is why enabling it again later is silent. That is expected, not a leftover.
{{< /callout >}}

## Stuck on "Approval required"

1. Use the **Open Login Items & Extensions** button on the endpoint.
2. Find Quorra under **Extensions** and confirm its Network Extension is on.
3. Confirm Quorra is running from `/Applications`. macOS will not approve the extension anywhere else.
4. If macOS says a restart is required, restart before enabling the endpoint again.

## Installed, but nothing answers

If the extension is installed and the endpoint still cannot connect, the saved routing configuration is likely the problem rather than the approval.

**Settings → IMDS → Recreate Routing Configuration…** replaces the saved macOS Network Extension configuration while keeping the system-extension approval, so you are not sent back through the approval flow.

## Uninstalling

Turn the default endpoint off before removing Quorra, so its transparent proxy configuration goes with it. macOS removes the system extension along with its containing app, and may ask you to confirm.

The switch in Login Items & Extensions disables the extension. It does not uninstall it.
