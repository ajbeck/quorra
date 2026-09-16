# Sign-in calls to action

Status: approved by AJ on 15 September 2026; implemented as `feat/sign-in-calls-to-action` on stack #65 above `fix/portal-region`.

## Why

Three reports from AJ on 14 and 15 September 2026: the IMDS endpoint detail offered no way to start sign-in once the served session's token had expired; the app opened a modal alert at launch when the Default IMDS Endpoint was set to run and its session needed sign-in; the menu bar had no way to change the served profile and no way to start sign-in.

## Decisions

### D1. One readiness answer

`ProfileCredentialReadiness` in `QuorraAppLogic` resolves `checking`, `signingIn`, `needsSignIn(sessionName:)`, `ready`, or `unavailable` from the pieces `CredentialsModel` caches: session status, profile status, in-flight sign-in, rejected role, and the refresh-failure overlay. The session status wins because it is the fresher signal. An expired session that still holds a refresh token stays `ready` until a refresh has failed, so silent refresh is unchanged; once one fails it becomes `needsSignIn`. The endpoint detail, the menu bar, the runtime coordinator's notice, and the IPC "authentication required" error all use it, replacing the detail view's private state machine and the coordinator's string matching.

### D2. No alert at launch

The HIG: "Avoid showing an alert when your app starts... consider alternative ways to let people know" and "Avoid using an alert merely to provide information" (https://developer.apple.com/design/human-interface-guidelines/alerts). The RootView alert is gone. The notice stays as coordinator state and drives the in-app calls to action.

### D3. The notification carries the action

The coordinator already posted a notification when a restore failed but suppressed it in the foreground because the alert existed. It is now shown as a banner in the foreground too and registers a category with a Sign In action that starts the device flow through the runtime coordinator; the browser opens as it does for any sign-in. Clicking the body opens the endpoint detail as before. The HIG asks for actions that "let people perform common, time-saving tasks that eliminate the need to open your app" and never one that "merely opens your app" (https://developer.apple.com/design/human-interface-guidelines/notifications#Notification-actions). The notice is also raised when a running default endpoint's session expires, not only when a restore fails, because the endpoint keeps serving cached credentials and nothing else would tell the user.

### D4. Endpoint detail

The credential prompt depends on the session, not on the run state. A running endpoint whose session needs sign-in shows the prompt with the cached credentials' expiry and a prominent Sign In as its primary action; Restart returns once credentials are ready. Stopped and failed endpoints keep the existing Sign In path. Sign-in goes through the view's existing helper, which re-enables the default endpoint and requests notification permission, so the coordinator restarts it after sign-in. Custom endpoints do not restart on their own; their detail shows Start when ready.

### D5. Menu bar

Two additions to the top group: "Sign In to session…" appears first whenever the served profile's session needs sign-in, wired to the coordinator's sign-in; a "Serve Profile" picker lists the eligible profiles from the store as a submenu with the current one checked (one submenu level, per the HIG on menus). A menu cannot show an error, so a failed switch opens the endpoint detail where the failure is displayed. The "Serving profile" line stays for at-a-glance status. The menu bar icon itself changes state (AJ agreed on 15 September 2026): while the served profile needs sign-in, the label swaps the Quorra glyph for the `person.badge.key` symbol the other calls to action use, through `MenuBarExtra(content:label:)` (macOS 13 and later, https://developer.apple.com/documentation/swiftui/menubarextra/init(content:label:)). System extras such as Wi-Fi and Battery change their symbol with state, so no badged asset is needed.

## Verification (15 September 2026)

- Warning-free build; the `quorra` test plan passes 518 tests, five of them new (`ProfileCredentialReadinessTests`).
- Previews: "IMDS Detail - running, session expired" (new) shows the orange prompt with the cached-credential expiry, a prominent Sign In, and Stop; "IMDS Detail - default" still shows Restart and Stop with no prompt.
- Launch against the real store with the default endpoint set to run and its session expired: the restore fails with "Your session token has expired", no alert appears, the endpoint shows as failed over IPC, and the unified log shows the app registering the `DEFAULT_IMDS_ENDPOINT_AUTHENTICATION_REQUIRED` category with its Sign In action. The notification itself was not posted because the Debug bundle is not authorized for notifications on this Mac, which is the documented guard: authorization is requested when the user enables the persistent endpoint or starts a sign-in. The banner and the menu bar items were not checked on screen in this pass.
