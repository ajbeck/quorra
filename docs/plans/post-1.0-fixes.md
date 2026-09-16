# Post-1.0 fixes

Follow-ups AJ reported on 16 September 2026 after installing 1.0.0. Each lands as a layer on stack #80.

## D1. ⌘Q keeps the menu bar item (PR #78)

Recorded as the 16 September 2026 update to D008 in `docs/architecture/cli-background-roadmap.md`: in menu-bar-only mode, `applicationShouldTerminate` closes the app's windows and cancels the quit; explicit quits and Apple-event quits proceed. Verified by AJ with the keyboard.

## D2. Stable menu bar icon (PR #79)

Recorded as the reversal note in D5 of `docs/plans/sign-in-calls-to-action.md`: the label always shows the Quorra glyph.

## D3. Profile detail draws once (PR #81, approved by AJ on 16 September 2026)

AJ saw the Credentials card draw twice when selecting a profile, with a different first draw, and endpoint switches draw once. Three things made the first frame of a profile switch wrong, all found by reading the profile path against the endpoint path:

1. The detail column's `switch` keeps the same `ProfileDetailView` (and the same `CredentialsRevealSection` inside it) across profile selections, because both are the same branch of the switch. So for the first frame the card still held the previous profile's credentials, and its `onChange(of: status)` fired (each profile's `ready` status carries its own expiry) and started a forced re-fetch, which set `isFetching` and drew the spinner rows, a different height, until the async read returned. The edit draft carried over the same way, so the header showed "Unsaved changes" until `onChange(of: stored)` replaced it. The endpoint detail has no such state.
2. Even with fresh state, the card read its values back through the model, the service actor, and the Keychain actor, which cannot finish before the first frame.
3. A profile selected for the first time in the app's life had no observed status yet, so the card drew "Checking" and then "ready". Before the native-list migration the profile rows observed each status as they appeared; the object list rows no longer do.

Decision, one change per cause:

1. Explicit identity per item in `DetailView`: `ProfileDetailView` and `SessionDetailView` get `.id(name)`. Apple's `id(_:)` reference: "When the proxy value specified by the id parameter changes, the identity of the view — for example, its state — is reset." A profile switch is therefore a new view whose draft and card state start from the new profile, and `onChange` does not fire for an initial value.
2. `IdentityCenterServicing` gains `cachedCredentials(forSession:accountId:roleName:)`, a synchronous, Keychain-only read that applies the same freshness rule as `liveCredentials` (inside the refresh skew counts as absent) and returns nil otherwise; `liveCredentials` now uses it for its cached path so the two cannot disagree. `KeychainStore` gains `readSynchronously(service:account:)`, which the production `Keychain` serves outside its actor: the wrapper holds only the access group, Apple's `kSecUseDataProtectionKeychain` reference says items accessed with that key behave like iOS keychain items, and Apple's Working with Concurrency page describes the iOS Security API as thread-safe and reentrant, with the macOS caveat (calls that block on a keychain unlock prompt) belonging to the legacy keychain that Quorra never uses. The card reads the accessor in the synchronous part of its `task(id:)`, before the first `await`; Apple documents that modifier as adding "a task to perform before this view appears or when a specified value changes", and AJ's recording showed that the state set there lands in the first frame. Missing or stale rows leave the value nil and the async mint runs as before, with the spinner. Secrets still never enter the observable model.
3. `ObjectListView` observes every profile's session and profile status in a `task(id:)` keyed by the profile keys, the role the old rows had; entries already cached return at once and the event stream keeps them fresh (D30).

Superseded: the first attempt on this layer drew masked placeholder rows for 200 ms instead of the spinner, and the second added only the synchronous read. AJ saw the flash still there both times, because the forced re-fetch and the carried-over state (cause 1) still produced a different first draw.

Sources: `id(_:)` https://developer.apple.com/documentation/swiftui/view/id(_:), `task(id:priority:_:)` https://developer.apple.com/documentation/swiftui/view/task(id:priority:_:), `kSecUseDataProtectionKeychain` https://developer.apple.com/documentation/security/ksecusedataprotectionkeychain, Working with Concurrency https://developer.apple.com/documentation/security/working-with-concurrency.

Verification: unit tests for the accessor (fresh row returned, inside the skew window nil, missing nil) and the existing `liveCredentials` suite; Debug run on AJ's Mac while AJ switched profiles.

## D4. Shell picker width (approved by AJ on 16 September 2026)

After D3, AJ noticed that the Credentials card's shell picker was not the same width on a profile with credentials as on one without. Measured from rendered previews of the card: the segmented control drew 297 pt wide whenever the card state was ready and 302.5 pt in every other state, the same across repeated renders, with the same font and the same height. The picker had `.frame(width: 300)`, and the control's natural width is 302.5 pt, so the frame under-proposed by 2.5 pt and the control resolved the shortfall differently by state: compressed in the ready state, overflowing and shifted 3 pt left in the others. With `fixedSize()` in place of the frame the control is 302.5 pt in both states. The countdown's `TimelineView` was ruled out first (the widths did not change without it).

Decision: `fixedSize()` replaces the fixed frame. Apple's reference: "Fixes this view at its ideal size." (https://developer.apple.com/documentation/swiftui/view/fixedsize()). The row's footprint is unchanged in practice (the label plus a picker of about 300 pt), so nothing narrower breaks that did not already.

Verification: rendered previews of the ready and role-rejected states measure the same control width; Debug run on AJ's Mac.
