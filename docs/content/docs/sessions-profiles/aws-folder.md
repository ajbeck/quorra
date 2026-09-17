---
title: "Your AWS folder"
description: "How Quorra imports your sessions and profiles, and what it writes back if you let it."
weight: 30
---
Quorra keeps sessions and profiles in its own store. It reads your AWS folder once, on first run, and writes back only if you ask it to.

## The import

On first run you choose the folder Quorra may access — normally `~/.aws`. Quorra reads the `sso-session` and `profile` sections it finds in `config` and copies them into its store. After that, the store is the source of truth: editing a profile in Quorra changes Quorra's copy.

You can re-read the folder at any time with **Re-import from AWS Folder** in **Settings → General**.

## Export, or not

**Export to AWS folder** decides whether Quorra writes back.

With export **on**, Quorra writes the sessions and profiles it manages into `config` whenever its store changes, so the AWS CLI and SDKs can use them. It adds a `# Managed by Quorra` header and normalises spacing to `=`.

{{< callout kind="note" >}}
Quorra updates only the `sso-session` and `profile` sections it manages. Your other sections, keys and comments are kept as they are.
{{< /callout >}}

With export **off**, Quorra never writes to your AWS files at all. Choose this if you hand-edit them, or if you would rather nothing outside Quorra changed.

The switch lives in **Settings → General**, and you can change it whenever you like. Turning it on triggers an export straight away.

## If an export fails

Settings shows the failure with a **Retry**. Common causes are the folder no longer being where you pointed Quorra, or macOS having revoked access to it — in which case Quorra asks you to choose the folder again.

## A non-standard folder

If you point Quorra somewhere other than `~/.aws`, it warns you once. AWS SDKs read `~/.aws` unless `AWS_CONFIG_FILE` says otherwise, so exporting to a folder the SDKs do not read will not do what you expect.
