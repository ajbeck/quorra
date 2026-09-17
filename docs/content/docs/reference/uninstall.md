---
title: "Uninstall"
description: "Remove Quorra cleanly, including its routing configuration."
weight: 30
---
Do these in order. The first step is the one people miss.

1. **Turn off the default endpoint.** This removes its transparent proxy configuration. Skipping it leaves that configuration behind after the app is gone.
2. Quit Quorra.
3. Move `Quorra.app` from `/Applications` to the Trash.

macOS removes the system extension along with its containing app, and may ask you to confirm.

{{< callout kind="warn" >}}
The switch in **Login Items & Extensions** disables the extension. It does not uninstall it. Removing the app is what removes the extension.
{{< /callout >}}

## What is left behind

Your AWS folder is untouched by uninstalling. If you had export on, the sessions and profiles Quorra wrote into `config` stay there and keep working with the AWS CLI — they are ordinary config sections.

Keychain items are removed with the app's keychain access. If you want to be certain, search for Quorra in Keychain Access after uninstalling.
