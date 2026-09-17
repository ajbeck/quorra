---
title: "Settings"
description: "What each of Quorra's four settings tabs controls."
weight: 10
---
## General

**AWS configuration** shows the folder Quorra has access to, with **Choose Folder…** to point it somewhere else and **Re-import from AWS Folder** to read it again.

**Export** holds the **Export to AWS folder** switch. With it on, Quorra writes the sessions and profiles it manages back to `config` whenever its store changes. Failures show here with a **Retry**.

## Background

**App presence** decides whether Quorra keeps a Dock icon. With it off, Quorra hides the Dock icon after you close its last window and carries on in the menu bar. Opening Quorra always shows the Dock icon again.

This tab is also where you start Quorra at login. Note that opening at login also opens the main window; turn **Keep Quorra in the Dock** off for a quiet background launch.

**Command-line tool** installs, repairs or removes the `quorra` command.

## IMDS

**Default endpoint** shows the address it claims — `169.254.169.254:80` — and explains the routing: Quorra sends only TCP connections for that address through its Network Extension, which relays opaque bytes to the local IMDSv2 server and never interprets, stores or logs credentials or tokens.

**System integration** is where you repair things. **Recreate Routing Configuration…** replaces the saved Network Extension configuration while keeping the system-extension approval.

{{< callout kind="note" >}}
The system extension stays installed when routing is turned off. This avoids repeating the macOS approval, and is normal.
{{< /callout >}}

## About

Version, licence, and **Check for Updates…**.
