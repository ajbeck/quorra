---
title: "Install Quorra"
description: "Download the disk image, move Quorra to Applications, and point it at your AWS folder."
weight: 10
---
Quorra requires an Apple silicon Mac running macOS 26.4 (Tahoe) or later.

## Download and install

1. Download `Quorra.dmg` from the [latest release](https://github.com/ajbeck/quorra/releases/latest).
2. Open the disk image and move `Quorra.app` to `/Applications`.
3. Open Quorra and grant access to your AWS folder, normally `~/.aws`. Quorra imports the IAM Identity Center sessions and profiles it finds there.

{{< callout kind="note" >}}
Quorra must be installed in `/Applications` before the default endpoint can be enabled. macOS will not approve the system extension anywhere else.
{{< /callout >}}

## Choose how Quorra treats your AWS files

On first run Quorra asks what it may do with the folder you picked.

**Export to AWS Folder** lets Quorra write the sessions and profiles you manage back to the `config` file, so the AWS CLI and SDKs can use them. Quorra updates only the `sso-session` and `profile` sections it manages, and keeps your other sections, keys and comments.

**Keep in Quorra** imports once and never writes to your AWS files. Choose this if you hand-edit them.

Either way you can change your mind later in **Settings → General**.

## Upgrading from 0.6

The first launch of 1.0 or later imports the sessions and profiles from your AWS folder into Quorra's own store.

If you used **Edit & Manage** and export is on, that same launch writes the imported sessions and profiles back to `config`, adding a `# Managed by Quorra` header and normalising spacing while keeping your other sections, keys and comments. **Read Only** becomes export off, and nothing is written.

Folders are gone. Sessions, profiles and endpoints are listed by kind in the sidebar.
