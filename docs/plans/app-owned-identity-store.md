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
(main) <- refactor/native-list <- feat/remove-folders <- feat/identity-store-models <- feat/identity-store-import <- feat/identity-store-ui <- feat/identity-store-export <- feat/identity-store-cli
```

- `models`: the two entities, the endpoint link, schema registration, tests.
- `import`: read the AWS folder once and populate the store; map endpoint `profileName` to the imported profile.
- `ui`: sidebar, object list, detail views, creation flows, and the IMDS model read the store; sign-in resolves sessions from the store.
- `export`: opt-in one-way writer; settings; the read-only mode becomes the export switch.
- `cli`: profile listing over IPC; remove the file reader from the CLI.

## Decisions

### D1. Names and files

`SessionDefinition` and `ProfileDefinition`, one type per file under `Packages/QuorraCore/Sources/QuorraAppLogic/Identity/`, registered in `QuorraMetadataSchema`. The names parallel `IMDSEndpointDefinition`, and the UI vocabulary (Sessions, Profiles) is unchanged.

### D2. Relationships, not id strings

The folder feature linked records by id strings. The identity model uses SwiftData relationships because the delete semantics matter: `SessionDefinition.profiles` cascades so deleting a session removes its profiles, and `ProfileDefinition.endpoints` nullifies so deleting a profile leaves its endpoints without a profile rather than dangling by name. Apple: "To specify a different deletion rule, annotate the property with the `Relationship` macro" (https://developer.apple.com/documentation/SwiftData/Preserving-your-apps-model-data-across-launches). Relationships are optional on the to-one side, the shape Apple documents as the safe one.

### D3. Names are unique

`#Unique` on `name` for both entities (https://developer.apple.com/documentation/SwiftData/Unique(_:)). Export writes `[sso-session name]` and `[profile name]` sections and the CLI addresses profiles by name, so two records with one name cannot be represented. SwiftData resolves a duplicate as an upsert, and the tests pin that.

### D4. The endpoint keeps `profileName` until import lands

`IMDSEndpointDefinition` gains an optional `profile` relationship in the models layer. `profileName` stays so existing endpoints keep working until the import layer maps names to records; the ui layer stops reading it and a later layer removes it.

### D5. Migration

Adding entities and an optional relationship is a lightweight change; no `VersionedSchema`, for the reason recorded in `docs/plans/remove-folders.md` D2. Verify by launching against an existing store.

## Verification

- `models`: warning-free build, package tests for cascade, nullify, and upsert; launch against an existing store.
