---
title: "Install Quorra"
description: "Download the disk image, move Quorra to Applications, and open it."
weight: 10
---
Quorra requires an Apple silicon Mac running macOS 26.4 (Tahoe) or later.

## Download and install

1. Download `Quorra.dmg` from the [latest release](https://github.com/ajbeck/quorra/releases/latest).
2. Open the disk image and move `Quorra.app` to `/Applications`.
3. Open Quorra. It imports the IAM Identity Center sessions and profiles it finds in `~/.aws`.

{{< callout kind="note" >}}
Quorra must be installed in `/Applications` before the default endpoint can be enabled. macOS will not approve the system extension anywhere else.
{{< /callout >}}

## How Quorra treats your AWS files

A new install reads your AWS folder and never writes to it. Keep your configuration somewhere other than `~/.aws`? Choose that folder in **Settings → General**.

Turn on **Export to AWS folder** in **Settings → General** to have Quorra write the sessions and profiles you manage back to the `config` file, so the AWS CLI and SDKs can use them. Quorra updates only the `sso-session` and `profile` sections it manages, and keeps your other sections, keys and comments.

## Upgrading from 0.6

The first launch of 1.0 or later imports the sessions and profiles from your AWS folder into Quorra's own store.

If you used **Edit & Manage** and export is on, that same launch writes the imported sessions and profiles back to `config`, adding a `# Managed by Quorra` header and normalising spacing while keeping your other sections, keys and comments. **Read Only** becomes export off, and nothing is written.

Folders are gone. Sessions, profiles and endpoints are listed by kind in the sidebar.
