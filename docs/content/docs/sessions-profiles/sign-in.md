---
title: "Sign in with Identity Center"
description: "Authorise a session in your browser, and let Quorra keep it refreshed."
weight: 10
---
Quorra signs in to AWS IAM Identity Center itself, using the native device authorization flow. You do not need the AWS CLI installed to sign in.

## Sign in

Select a session in the sidebar and choose **Sign In**. Quorra opens your browser at the Identity Center portal and shows the user code to confirm. Approve it there, and Quorra picks up the token as soon as AWS confirms.

While a sign-in is in progress, the menu bar shows the code and its expiry, and offers to reopen the authorisation page if you lost the tab.

{{< callout kind="note" >}}
The access token is stored in the macOS Keychain, not in Quorra's application files.
{{< /callout >}}

## What expires, and when

Two different clocks matter, and the app shows both.

|                  | What it is                                   | What happens when it runs out                                     |
| ---------------- | -------------------------------------------- | ----------------------------------------------------------------- |
| Session token    | The Identity Center token from signing in    | You sign in again                                                 |
| Role credentials | Temporary credentials for one profile's role | Quorra mints new ones, silently, while the session is still valid |

So a profile's credentials expiring is routine and needs nothing from you. The session expiring is the one that asks you to sign in again.

## Refreshing

Quorra refreshes the session token in the background while it remains valid. If a refresh fails, the session detail says so and offers **Refresh now**.

You can also sign in from the menu bar, from a profile that needs it, from a running endpoint whose served profile has gone stale, or from the command line:

```console
$ quorra profiles sign-in ac:cp:org_admin
```

## Signing out

**Sign out** on a session clears its token. If Quorra cannot reach AWS to invalidate the token remotely, it says so — the local copy is gone either way, and the token expires on its own within eight hours.
