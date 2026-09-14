# Remove metadata folders

Status: implemented on branch `remove-folders`, 14 September 2026. Approved by AJ the same day as Q3 of `native-list-migration.md`.

## What goes

The folder feature let a user group sessions, profiles, and IMDS endpoints under named folders in the sidebar. It arrived in one squashed commit (`2368a53`), had one eight-line test, and no mention in the README, changelog, or docs. Removing it deletes two SwiftData entities (`MetadataFolder`, `MetadataFolderAssignment`), the unused `folderIDString` attribute on `IMDSEndpointDefinition`, `MetadataFolderPicker`, `MetadataObjectDragPayload` and its drag and drop wiring, the `.folder` case of `SourceSelection`, the folder sheets and context menus in the sidebar, the assignment menu in the object list, and the Organization sections of the three detail views. The sidebar is now four static rows, so the D10 and D11 constraints from the List migration no longer apply to it.

## Decisions

### D1. Land it as its own change on top of the List migration

The migration was verified before this work started, so this branch is deletions only: 11 files, 9 insertions, 849 deletions. Alternative considered: remove folders first and redo the migration on simpler code. Rejected because it throws away verified work.

### D2. No `VersionedSchema` or `SchemaMigrationPlan` for this change

Removing entities and attributes is a change Core Data's inferred lightweight migration handles on its own ("Migrating your data model automatically", https://developer.apple.com/documentation/CoreData/migrating-your-data-model-automatically), and SwiftData's `ModelContainer` performs that inference when no migration plan is supplied. Declaring a versioned schema would require keeping the deleted `@Model` classes in the codebase forever as the V1 definition, which is more code than the feature itself. Adopt `VersionedSchema` and `MigrationStage` (https://developer.apple.com/documentation/SwiftData/SchemaMigrationPlan) only when a change needs a custom stage.

### D3. Verification

- Warning-free build and the full `quorra` test plan: 508 tests, 0 failures (one folder test removed).
- Sidebar and object list previews render.
- Launch the build against the existing on-disk store to exercise the inferred migration. Done 14 September 2026: the app stayed up for two minutes with no crash log, and the container is created with `try!` during app delegate init, so the migration succeeded on the real store. The shell cannot read the sandbox container (macOS privacy protection hides it), so the store was not backed up first; a failed lightweight migration leaves the source store untouched, and the 0.6.1 release build can still open a store that only lost entities it does not read.
