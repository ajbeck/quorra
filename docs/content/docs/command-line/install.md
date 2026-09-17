---
title: "Install the quorra command"
description: "A stable command that always runs the CLI shipped with the current app."
weight: 10
---
Quorra ships a command-line tool inside the app bundle. Rather than asking you to reference a path inside `Quorra.app`, it installs a stable `quorra` command that always points at the CLI in the app you are currently running — so upgrading the app upgrades the command.

## Set it up

Go to **Settings → Background → Command-line tool** and choose **Set Up…**. Pick a folder that is already on your `PATH`, and Quorra links the command there.

{{< callout kind="note" >}}
Quorra does not edit your shell configuration. The folder you choose must already be on your `PATH`.
{{< /callout >}}

Check it:

```console
$ quorra version
```

## Most commands need the app running

Only `quorra version` stands alone. Everything else talks to the running Quorra app over local IPC, because the app owns the identity store and the endpoints.

If the app is not running, start it:

```console
$ quorra start
```

`quorra stop` stops it again.

## If Settings says something is wrong

| What it says                                           | What it means                                                                                       |
| ------------------------------------------------------ | --------------------------------------------------------------------------------------------------- |
| Not installed                                          | No command has been linked yet                                                                      |
| The command link needs repair                          | The link is there but no longer resolves — **Repair** relinks it                                  |
| Another item already uses this command path            | Something else is called `quorra` in that folder. Quorra will not replace it; choose another folder |
| Quorra no longer has access to the installation folder | macOS revoked the folder permission — choose the folder again                                     |
