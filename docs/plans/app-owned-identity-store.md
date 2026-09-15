# App-owned identity store

Status: approved by AJ on 14 September 2026; in progress as a stack of PRs on top of `feat/remove-folders` (PR #64).

## Why

Quorra already owns the whole credential path: sign-in, tokens and role credentials in Keychain, role credential minting, the IMDS backend, and the system extension that answers at `169.254.169.254`. The only thing it still reads from `~/.aws/config` is the profile record an endpoint needs (`App/IMDS/IMDSModel.swift`, `startEndpoint(for:)`: session name, account id, role name, region) and the `sso-session` block for sign-in. AWS documents IMDS as the last provider in the chain and says that to use it "you must remove other valid credential providers from your configuration or use a different profile" (https://docs.aws.amazon.com/sdkref/latest/guide/feature-imds-credentials.html), so a config file full of SSO profiles competes with Quorra's endpoint. The SSO provider reads its token from `~/.aws/sso/cache` (https://docs.aws.amazon.com/sdkref/latest/guide/feature-sso-credentials.html), so a named SSO profile needs its own `aws sso login` whoever wrote it; exporting profiles never made the CLI share Quorra's login.

## Approved shape (AJ, 14 September 2026)

1. Two SwiftData entities beside the IMDS ones: a session definition (start URL, Identity Center region, scopes, name) and a profile definition (session, account, role, region, name). Endpoint definitions link to a profile by identity, not by name string.
2. Creating a profile picks the account and role from the portal listing after sign-in.
3. One-time import from the selected AWS folder on first launch of the new version, so existing users keep their sessions and SSO profiles.
4. Export is one-way and opt-in: Quorra writes its own `sso-session` and `profile` sections under the existing managed header and never reads the file back as truth. Read-only mode becomes "export off".
5. The CLI's profile list moves from reading the file to asking the app over IPC.

Product decision, also approved: Quorra is an identity manager, not a config editor. Static-key, assume-role, and credential_process profiles are no longer listed or edited; they stay untouched in the file.

Costs accepted: the standardized region setting has no IMDS fallback (https://docs.aws.amazon.com/sdkref/latest/guide/feature-region.html), so users without a config file set `AWS_REGION` or keep a one-line default section that export can write; anything left in the default profile or `AWS_PROFILE` pre-empts IMDS, so import shows what the file still contains.

## Stack

```
(main) <- refactor/native-list <- feat/remove-folders <- feat/identity-store-models <- feat/identity-store-import <- feat/identity-store-runtime <- feat/identity-store-ui <- feat/identity-store-export <- feat/identity-store-cli
```

- `models`: the two entities, the endpoint link, schema registration, tests.
- `import`: read the AWS folder once and populate the store; map endpoint `profileName` to the imported profile.
- `runtime`: the IMDS engine, the runtime coordinator, the default-endpoint repair, the IPC sign-in coordinator, and the IMDS detail view resolve profiles and sessions from the store; reconciliation also runs when a save touches identity entities.
- `ui`: sidebar, object list, session and profile detail views, creation and deletion flows read the store; `ProfilesModel` leaves the app.
- `export`: opt-in one-way writer; settings; the read-only mode becomes the export switch.
- `cli`: profile listing over IPC; remove the file reader from the CLI.
- `fix/portal-region` (folded into the stack above `ui` on 15 September 2026): role-credential minting calls the Portal in the session's Identity Center region, which the stored token records, instead of the profile's default region. The profile region stays on the minted credential for SDK use.
- `feat/sign-in-calls-to-action` (above `fix/portal-region`, 15 September 2026): shared credential readiness, sign-in calls to action in the endpoint detail, the notification, and the menu bar; the launch alert is gone. Decisions in `docs/plans/sign-in-calls-to-action.md`.
- `feat/identity-store-export` (above `feat/sign-in-calls-to-action`, 15 September 2026): the store-to-file writer (D13, D14), the export switch, the re-import action, and the setup copy. Verified 15 September 2026: warning-free build, 527 tests (9 new in `IdentityStoreExporterTests`, including a real temp-file write through the shared lock), previews of General settings (ready, export failed) and Setup, and a real-store launch that leaves the config file untouched because nothing saved. A live export against a real AWS folder was deliberately not run on AJ's machine.
- `feat/identity-store-cli` (above `feat/identity-store-export`, 15 September 2026): `profiles list` over IPC (D15); the CLI file reader and its options removed. Verified 15 September 2026: warning-free build, 525 tests (three file-location tests removed, one parsing test added), and a real-store launch where `quorra-cli profiles list` returned the store's five profiles in table, names, and JSON form over IPC and rejected `--config-file`.

## Decisions

### D1. Names and files

`SessionDefinition` and `ProfileDefinition`, one type per file under `Packages/QuorraCore/Sources/QuorraAppLogic/Identity/`, registered in `QuorraMetadataSchema`. The names parallel `IMDSEndpointDefinition`, and the UI vocabulary (Sessions, Profiles) is unchanged.

### D2. Relationships, not id strings

The folder feature linked records by id strings. The identity model uses SwiftData relationships because the delete semantics matter: `SessionDefinition.profiles` cascades so deleting a session removes its profiles, and `ProfileDefinition.endpoints` nullifies so deleting a profile leaves its endpoints without a profile rather than dangling by name. Apple: "To specify a different deletion rule, annotate the property with the `Relationship` macro" (https://developer.apple.com/documentation/SwiftData/Preserving-your-apps-model-data-across-launches). Relationships are optional on the to-one side, the shape Apple documents as the safe one.

### D3. Names are unique

`#Unique` on `name` for both entities (https://developer.apple.com/documentation/SwiftData/Unique(_:)). Export writes `[sso-session name]` and `[profile name]` sections and the CLI addresses profiles by name, so two records with one name cannot be represented. SwiftData resolves a duplicate as an upsert, and the tests pin that.

### D4. The endpoint keeps `profileName` until import lands

`IMDSEndpointDefinition` gains an optional `profile` relationship in the models layer. `profileName` stays so existing endpoints keep working until the import layer maps names to records; the ui layer stops reading it and a later layer removes it.

### D8. The runtime keys profiles by name, from the store

Every runtime path (endpoint start and switch, the default endpoint, IPC) already addressed profiles by name, and names are unique in the store, so the runtime keeps name-keyed APIs and resolves them through `IdentityStore` lookups. Endpoint writes set both `profileName` and the `profile` relationship so either can be read. Reconciliation runs on `ModelContext.didSave` for the context that owns the store, filtered to identity entities so IMDS log batches do not trigger it; Apple recommends specifying the context as the notification object (https://developer.apple.com/documentation/SwiftData/ModelContext).

### D5. Migration

Adding entities and an optional relationship is a lightweight change; no `VersionedSchema`, for the reason recorded in `docs/plans/remove-folders.md` D2. Verify by launching against an existing store.

### D6. Import scope

Only `sso-session` sections and the profiles that reference them with an account id and a role name are imported. Legacy SSO profiles that carry `sso_start_url` themselves, profiles under a session with no start URL or region, and every non-SSO profile stay in the file untouched and are reported as skipped. AWS calls the legacy form "non-refreshable" and recommends the token provider form (https://docs.aws.amazon.com/sdkref/latest/guide/feature-sso-credentials.html), and `aws configure sso` writes the token provider form, so the legacy form is not worth a synthesized session.

### D7. Import trigger

The import runs once, in `AppRuntimeCoordinator` right after the first successful load of the AWS folder, and a UserDefaults flag (`IdentityImportStorage`) records completion. Failure leaves the flag unset so the next launch retries, and the error goes to the `dev.ajbeck.quorra` log. Records are matched by name, so a later manual re-import (a settings action in the export layer) updates rather than duplicates.

### D9. Store edits are not gated by the file mode

The managed and read-only modes described what Quorra may do to the AWS files. Sessions and profiles now live in the store, so the mode no longer applies to creating, editing, or deleting them, and the read-only banners and disabled controls are gone from those views. The mode setting stays in General settings until the export layer turns it into the export switch (approved shape, point 4). Until that layer lands nothing writes the AWS files, whatever the mode says.

### D10. `ProfilesModel` leaves the package too

Once the views read the store, nothing in the app or the CLI used `ProfilesModel` (the CLI reads through `ProfileCatalogLoader` in `QuorraProfiles`). The class, its file writers, and their tests are removed; the derivation tests exercise `ProfileCatalogLoader.derive` directly, which the import still relies on. The import loads the folder with `ProfileCatalogLoader.load(folder:)` off the main actor, as the model did.

### D11. Save and Discard drafts stay

Session and profile detail views keep an explicit draft compared against the stored values: Save validates, applies, and calls `modelContext.save()`; Discard resets; a failed save rolls the context back and shows the error. SwiftData autosave with inline editing was considered and rejected because these fields decide which credentials an endpoint serves, so the review step stays. Approved by AJ on 14 September 2026 (Q1).

### D12. Profile creation and the portal listing

The profile sheet lists accounts with `ListAccounts` and roles with `ListAccountRoles` through the session's stored token, on the portal host of the session's Identity Center region, which the token records. AWS: `sso_region` is "the AWS Region that contains your IAM Identity Center portal host" (https://docs.aws.amazon.com/sdkref/latest/guide/feature-sso-credentials.html). The two verbs are new on `IdentityCenterServicing` and `CredentialsModel`. A signed-out session (`.notSignedIn` or `.tokenExpired`) falls back to typed account ID and role name, with a footer that says to sign in. The default name is the session name, the portal account name (or the typed account ID), and the role name joined by colons, lowercased, with whitespace runs replaced by `-`; it is shown as the placeholder so the user can type another name. Sessions require an https start URL and a region at creation, since both are needed to sign in. Approved by AJ on 14 September 2026 (Q2).

### D13. Export ownership (approved by AJ on 15 September 2026)

The exporter owns keys, not sections, inside the same-named `sso-session` and `profile` sections of the AWS config file. Profiles own `sso_session`, `sso_account_id`, `sso_role_name`, and `region`; sessions own `sso_start_url`, `sso_region`, and `sso_registration_scopes`. On save it ensures the section exists and sets those keys, and never touches other keys or other sections. On delete in Quorra it removes the managed keys and drops the section only if it is then empty. This matches the AWS CLI, whose wizard writes `region` and `output` into the same profile section as the SSO keys and whose session wizard "updates the sso-session sections" in place (https://docs.aws.amazon.com/cli/latest/userguide/sso-configure-profile-token.html). Export runs on every identity save while the switch is on, from a store-save observer, and once in full when the switch is turned on. Re-import from the AWS folder is an upsert: same-named objects take the file's managed values, new sections are added, and nothing in the store is deleted.

### D14. Export switch, header, failures, and re-import (approved by AJ on 15 September 2026)

The managed and read-only modes become one switch, "Export to AWS folder", backed by the stored mode so existing preferences carry over: managed is on, read-only is off. Store edits never depend on it (D9). The header written on first export no longer claims the whole file; it says Quorra updates the sso-session and profile sections it lists, keeps other sections and keys, and normalizes formatting on write. Export failures are not alerts: the export coordinator records the last failure and General settings shows it under the switch with a Retry button; the store save itself is unaffected. "Re-import from AWS Folder" sits beside the folder row in General settings, runs the importer's upsert with no confirmation because nothing is deleted, and reports a one-line result. The button has no ellipsis because it opens nothing further.

### D15. The CLI lists profiles from the store (approved by AJ on 15 September 2026)

`quorra-cli profiles list` asks the running app over a new `profiles.list` IPC operation and no longer parses the AWS files itself. The `--config-file` and `--credentials-file` options are gone, since the file is no longer the source of truth and the CLI is pre-1.0; `--format` stays. The listing shows every profile in the store, linked to a session or not, and the `source` column and JSON field are gone because the store only holds Identity Center profiles. `QuorraCLIKit` no longer depends on `QuorraProfiles`. The command now needs the app running, which changes the roadmap's "intentionally standalone" note for this one command.

## Verification

- `models`: warning-free build, package tests for cascade, nullify, and upsert; launch against an existing store. Done 14 September 2026: 512 tests passed, launch against the real store succeeded.
- `import`: importer tests for scope, idempotence, and endpoint linking; launch against the real AWS folder and confirm the log line. Done 14 September 2026: 516 tests passed; the launch logged "Imported 1 sessions and 5 profiles into the identity store; linked 3 endpoints; left 0 profiles in the file."
- `runtime`: tests for store lookups, default-endpoint linking, and the IPC sign-in coordinator on a store; launch and query the running app over IPC. Done 14 September 2026: 517 tests passed; `quorra-cli imds list` and `imds status default` against the debug app listed every endpoint with its store-resolved profile, and the default endpoint reported the credential path's own "session token has expired" state rather than a lookup failure.
- `ui`: warning-free build; package tests for the portal listing verbs; previews of the object list, the creation sheets, and both detail views render on fixture data; launch against the real store and query it over IPC. Done 14 September 2026: 512 tests passed (the seven `ProfilesModel` file-writer tests left with the class, two portal listing tests joined); the six previews rendered; the debug app launched against the real store with no crash report, and `quorra-cli imds list` listed every endpoint with its store-resolved profile while the default endpoint still reported the credential path's own expired-token state.
