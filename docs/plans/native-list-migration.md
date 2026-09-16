# Native List Migration Plan

This document is the working plan and decision log for moving Quorra's two navigation columns, the source sidebar and the object list, from hand-built button stacks onto SwiftUI `List`. It records each decision with its Apple citation so future sessions read this instead of the conversation. Update it whenever scope, status, or a decision changes.

## Goal

Both navigation columns become native macOS lists so that keyboard navigation, type-to-select, VoiceOver selection state, the system sidebar icon-size setting, the native selection highlight, and the sidebar material all come from the platform instead of custom code. This is recommendation 1 of the 14 September 2026 HIG review.

## Scope

In scope:

- `SourceSidebarView` in `App/Views/SessionRailView.swift` becomes `List(selection:)` with `.listStyle(.sidebar)`.
- `ObjectListView` in `App/Views/ProfileListView.swift` becomes `List(selection:)` in the content column.
- Count capsules become native badges.
- `NavigationRowButtonStyle` in `App/Views/Controls/InteractionFeedback.swift` is deleted once both callers are gone.
- Preview harnesses in both files keep rendering.

Out of scope, deliberately, so verification stays clean:

- Row visuals (`ObjectListRow`, via badges, status icons).
- Moving the plus and minus controls to the toolbar, and menu bar commands. Those are HIG review recommendation 2.
- Dropping `name` from `SourceSelection.folder`. See D6.
- The unused `ProfileRow` and `SessionRow` in `App/Views/SidebarRows/`. They have no callers today and are left alone.

## Design Graph

```text
MainView (NavigationSplitView)
├── sidebar column: SourceSidebarView
│   ├── List(selection: $selection)            non-optional binding, D1
│   ├── .listStyle(.sidebar)                   D3
│   ├── Section { All }                        headerless, replaces the Divider
│   └── Section { Sessions, folders…, Profiles, folders…, IMDS Endpoints, folders… }
│       ├── kind row  .tag(kind) .badge(count) .contextMenu(New Folder)
│       └── folder row .tag(.folder) .badge(count) .listRowInsets(.leading, +) .contextMenu .dropDestination
├── content column: ObjectListView
│   ├── header (title + count)                 Q1 open
│   ├── List(selection: $detailSelection)      optional binding, D2
│   │   ├── flat rows or Section per kind when source is All
│   │   └── row .tag(item.detailSelection) .contextMenu(folder assignment) .draggable(payload)
│   └── bottom bar (plus, minus)               Q1 open
└── detail column: unchanged
```

## Decision Log

Each entry names the decision, the source that settles it, and the reasoning.

### D1. Sidebar selection uses the non-optional `List` initializer

`List` provides `init(selection: Binding<SelectionValue>, content:)`, documented as "Creates a list with the given content that supports selecting a single row that cannot be deselected." Source: https://developer.apple.com/documentation/SwiftUI/List/init(selection:content:)-590zm

`SourceSidebarView` already receives `Binding<SourceSelection>`, and `MainView` builds that binding with a setter that clears the detail selection whenever the source changes. Passing the same binding to `List` keeps that behavior with no wrapper and guarantees the sidebar always has a source, which matches the current design. `SourceSelection` is already `Hashable`, so rows tag with the enum value directly.

### D2. Object list selection uses the optional `List` initializer

`List` provides `init(selection: Binding<SelectionValue?>?, content:)` for "selecting a single row." Source: https://developer.apple.com/documentation/SwiftUI/List/init(selection:content:)-1pisz

`ObjectListView` receives `Binding<DetailSelection?>`, and an empty detail is a valid state, so the optional form is the direct fit. Rows use `.tag(item.detailSelection)`. The `tag(_:includeOptional:)` modifier writes both the non-optional and optional tag by default, so an optional selection matches a non-optional tag. Source: https://developer.apple.com/documentation/SwiftUI/View/tag(_:includeOptional:)

### D3. Sidebar style and hierarchy

`.listStyle(.sidebar)` gives the source-list appearance and material. Row height, text, and glyph size then follow `SidebarRowSize`, which "is primarily controlled by the current users' Sidebar Icon Size in Appearance settings, and applies to all applications." Source: https://developer.apple.com/documentation/SwiftUI/SidebarRowSize

Hierarchy stays flat: a selectable kind row followed by its folder rows, matching today's structure. Folder rows indent their content by 18 points of leading padding, the same amount as before. `listRowInsets(.leading, _)` was considered, but it sets an absolute inset ("changes the leading inset of each row of the list", source: https://developer.apple.com/documentation/SwiftUI/View/listRowInsets(_:_:)) and the sidebar style's default inset is not documented, so relative padding on the row content is the deterministic choice. The selection highlight still spans the full row, as it does for nested items in Finder.

Amended 14 September 2026 after D10 and D11: the second section is a single `ForEach` over a flat, precomputed array of `SourceSidebarItem` values (kind row, its folders, next kind row, and so on) instead of static kind rows interleaved with three folder `ForEach` calls. The visual result is identical; the structure exists so that every row in the selectable section has an identifier of the selection type and is built inline.

Collapsible sections were considered and deferred. A `Section` with an `isExpanded` binding "in a List that uses the sidebar style shows a disclosure indicator next to the section's header." Source: https://developer.apple.com/documentation/SwiftUI/Section#Collapsible-sections. The HIG suggests disclosure controls when an app "has a lot of content"; Quorra's folder lists are short, and the kind row itself is selectable, which a section header is not. Approved by AJ on 14 September 2026.

The All row sits in its own headerless `Section` so the native section spacing replaces today's `Divider`.

### D4. Counts become native badges

Rows use `.badge(count)`: "Badges appear in list rows, tab bars, toolbar items, and menus." The list applies `.badgeProminence(.decreased)`, which the documentation shows for "an informational badge with lower prominence, showing the number of items in the folder." Sources: https://developer.apple.com/documentation/SwiftUI/View/badge(_:)-8adyq and https://developer.apple.com/documentation/SwiftUI/BadgeProminence

Behavior change to note: the native badge hides at zero ("Set the value to zero to hide the badge"). Today an empty kind shows 0. Zero adds no information, so the native behavior is accepted.

### D5. Context menus, drop targets, and drag sources attach to rows

`.contextMenu` and `.dropDestination(for:)` move from the button wrappers onto the row content. Apple documents `dropDestination(for:isEnabled:action:)` on an item view inside a `ForEach` to "let people drop items from other apps directly onto a specific item in your container." Source: https://developer.apple.com/documentation/SwiftUI/Reordering-items-in-lists-stacks-grids-and-custom-layouts#Support-drag-and-drop-onto-individual-items-in-a-reorderable-container

Amended 14 September 2026: because kind rows and folder rows now come from one `ForEach` (D3), the sidebar uses `dropDestination(for:isEnabled:action:)` on every row with `isEnabled` true only for folder rows ("The Boolean value indicating if the view accepts drop interactions", source: https://developer.apple.com/documentation/SwiftUI/View/dropDestination(for:isEnabled:action:)). That variant's action returns nothing, so `assign(_:to:)` no longer returns a success flag; a drop whose payloads do not match the folder's kind is ignored instead of reported as failed. The context menu content is chosen per row with an `if let folder` inside the menu builder.

Object rows keep `.draggable(item.dragPayload)`; Apple shows `draggable` applied to row content inside a `List`. Source: https://developer.apple.com/documentation/SwiftUI/Adopting-drag-and-drop-using-SwiftUI#Enable-Drag-Interactions

### D6. Folder tag identity is unchanged this step

`SourceSelection.folder(kind:folderID:name:)` carries the folder name, so renaming a folder changes its tag. `renameFolder` in `SourceSidebarView` already reassigns the selection to the renamed value after saving, so the list re-selects the row. Removing `name` from the enum is the cleaner shape but touches `MainView`, `ObjectListView`, and the title lookup, and is deferred to keep this change surgical.

### D7. `NavigationRowButtonStyle` is deleted

Its only two callers are the two column views. Once both use `List`, the style is dead code created by this change and is removed. `pressFeedback()` and `CopyConfirmationButton` in the same file stay.

### D8. Row content is unchanged

`SourceSidebarRow` loses only its count capsule (replaced by D4). `ObjectListRow` is untouched. Visual changes to rows belong to later HIG recommendations.

### D9. Ownership

Fable: D1 through D4 in `SourceSidebarView`, end-to-end verification, `NavigationRowButtonStyle` removal, final diff review. Opus subagent: `ObjectListView` conversion using the sidebar diff as the reference pattern, with a brief that pre-loads the exact edits so its first action is an edit.

### D10. `ForEach` identifiers in a selectable list use the selection type

Found 14 September 2026 while rendering the sidebar preview with a folder seeded. A sidebar `List(selection:)` bound to `SourceSelection` crashed with `SwiftUI/TableViewListCore_Mac2.swift:5538: Fatal error` in `OutlineListCoordinator` as soon as a `ForEach` used `String` identifiers (`\.stableIDString`), with or without an explicit `.tag` of the selection type. The same list with identifiers of the selection type rendered. Both facts were established with throwaway previews containing nothing but `List`, `Section`, `Text`, and `ForEach`, so this is a platform constraint on macOS 27, not something in Quorra's rows.

The documentation describes the identifier-as-tag path: "A ForEach automatically applies a default tag to each enumerated view using the id parameter of the corresponding element. If the element's id parameter and the picker's selection input have exactly the same type, or the same type but optional, you can omit the explicit tag modifier." Source: https://developer.apple.com/documentation/SwiftUI/View/tag(_:includeOptional:)

Follow-up the same afternoon: seven standalone reproductions of the crashing shape (a `View` struct and an inline `@Previewable` preview, a local enum and the app's `MetadataObjectKind` payload, with and without a static tagged row beside the `ForEach`, light and dark) all rendered, and the only fresh crash log on disk was the unrelated preview hot-swap cast failure. The crash reproduced twenty times in the sidebar preview during the bisect and once in a bare smoke preview in the same file, so it was real for that file, but its minimal trigger is not known. Treat the rule as Apple's documented shape and the change that fixed the observed crash, not as a confirmed platform bug.

Applied: a file-private `MetadataFolder.sourceSelection` computed property builds `.folder(kind:folderID:name:)`, the item array is keyed by `\.selection`, and every row still carries an explicit `.tag` for symmetry with the All row. Consequence for D6: a folder's row identity now includes its name, so a rename replaces the row instead of updating it in place; `renameFolder` already reselects the renamed value. The same rule applies to `ObjectListView`: its `ForEach` must be keyed by `DetailSelection`, not by a string id.

### D11. Rows inside a `ForEach` are built inline, not through a view-returning helper

Found the same day, after D10, still in the preview host. With identifiers fixed, the sidebar preview kept crashing at the same assertion while a copy of the list with the folder row written inline rendered. The only difference was that the folder row came from the `sourceRow(...)` helper function; the earlier `@ViewBuilder` `folderRows(for:)` helper that returned the `ForEach` itself had the same effect. Xcode previews wrap view-returning functions for hot reload (`DebugReplaceableView` in the crash reports), and the wrapped row inside the outline list's `ForEach` trips the assertion. The live app has no such wrapper, so this is a preview-only failure, but previews are part of the verification contract, so the code avoids the pattern.

Applied: `sourceRow(_:title:systemImage:count:isNested:)` and `folderRows(for:)` are gone. The second section is one `ForEach` over `sourceItems`, an array of `SourceSidebarItem` values (selection, title, symbol, count, kind, optional folder), and the row modifiers are applied inline in the closure. Static rows outside a `ForEach` are unaffected, which is why the All row and the zero-folder sidebar never crashed. The preview harness seeds a `Work` folder under Profiles so this stays covered.

Rule for the Opus brief: inside a `List` `ForEach`, write the row content inline (a `View` struct such as `ObjectListRow` used as content is fine; a helper function that returns the row or the `ForEach` is not), and key the `ForEach` by the selection type.

### D12. `ObjectListRow` moves to its own file; the real shape of D11

The Opus conversion of `ObjectListView` followed D10 and D11 and still crashed at the same assertion in all three previews. Its bisect showed `Text` and a `View` from another file rendering as row content while `ObjectListRow` crashed, with or without its modifiers and with or without a container wrapped around it or around its body. `ObjectListRow` differs from every working row in one way: its `body` is a `switch` over the item kind, so its view-list representation is conditional content, and it was defined in the file being previewed. A probe that used `ProfileRow` from `App/Views/SidebarRows/ProfileRow.swift` (which also has conditional content in its body) as the row rendered fine.

So the D11 rule is really this: Xcode previews wrap every view-returning function and every `View` body defined in the file being previewed for hot reload, and a wrapped view whose content is not a single fixed view (a `ForEach`, a helper returning a row, a body that is `if` or `switch`) breaks the outline coordinator's row walk. Views defined in other files are not wrapped. The live app never wraps anything, which is why the running app did not crash on the sidebar's helper either.

Applied: `ObjectListRow` now lives in `App/Views/ObjectListRow.swift` with its two private helpers, `IMDSBadge` and the `ProfileVia.badgeColor` and `IMDSEndpointState.accent` extensions, which had no other callers. Its body is byte-for-byte the previous one, so D8 holds. `ObjectListItem` and `IMDSEndpointListItem` become internal instead of file-private because the row's stored property names them. The project's `App` folder is a synchronized group, so the new file needs no project edit, and one primary type per file matches AGENTS.md. `SourceSidebarRow` stays in `SessionRailView.swift` because its body is a plain `HStack` and it renders there.

Rule going forward: a `List` row view whose body has `if` or `switch` at any level belongs in its own file, not in the file whose preview renders the list.

### D13. Arrow keys move the list selection through `onMoveCommand`, with focus set by a click (15 September 2026)

AJ found that Up and Down arrows moved no selection in either column. A debug event monitor showed every arrow key reaching the app with the window itself as first responder: a click selected a row but never gave the `List` keyboard focus. The same held in a bare `NavigationSplitView` with two `List(selection:)` columns and with an NSTableView-backed `Table`, built against the macOS 27.0 SDK on macOS 27.0 (26A428). Apple's `List` and `NavigationSplitView` pages prescribe nothing beyond `List(selection:)` for arrow navigation and the macOS 27 release notes list no change. A first attempt made the `List` the root of the content column because background automation (computer-use `app_batch`, which posts input straight to the process) showed the selection moving after that change; AJ's keyboard and system-level synthesized input both disagreed, so that change was dropped. AJ's research pointed at the pattern from the WWDC23 session "The SwiftUI cookbook for focus" (https://developer.apple.com/videos/play/wwdc2023/10162/): make the list focusable and handle `onMoveCommand`, which Apple documents as the action to perform "when the user presses an arrow key on a Mac keyboard" (https://developer.apple.com/documentation/swiftui/view/onmovecommand(perform:)). Tested in the bare sample with system-level input: `.focusable()` plus `.onMoveCommand` alone never fired, because a click still did not focus the list. Adding a `@FocusState` bound with `focused(_:)` (https://developer.apple.com/documentation/swiftui/view/focused(_:)) and setting it from a `simultaneousGesture(TapGesture())` on the list made the click focus the list, and the arrows then moved the selection in both columns. `focusEffectDisabled()` (https://developer.apple.com/documentation/swiftui/view/focuseffectdisabled(_:)) hides the focus ring a focused list otherwise draws, matching Finder and Mail, where a clicked list shows no ring. Applied to both columns. The sidebar walks `SourceSelection.allCases` (the enum is now `CaseIterable`; declaration order is the sidebar order). The object list walks `visibleItems`, wraps its `List` in a `ScrollViewReader`, and calls `scrollTo` on the new row so a long list keeps the selection visible; with no selection, Down selects the first row and Up the last, as AppKit tables do. Focus is set only by a click, never by a selection change, so programmatic navigation (a source change, a search, a View button in a detail view) does not pull focus away from where the user is typing or arrowing. Type-to-select was dropped from scope by AJ the same day.

## Open Questions

### Q1. Object list chrome after migration

With a native `List`, the rounded card that wraps today's list and bottom bar goes away, because painting a content column with a custom fill is what the migration removes. What remains to decide is the header ("Profiles, 7 items") and the plus and minus bar.

Recommendation: keep the header as a plain view above the `List`, and keep the plus and minus bar as a `safeAreaInset(edge: .bottom)` on the `List`, unstyled beyond a top divider. Behavior is unchanged, the count stays visible, and recommendation 2 of the HIG review moves the bar's actions into the toolbar and menus later.

Alternative considered: drop the header and rely on the sidebar selection for context. Rejected for this step because the item count is useful and the change is unrelated to the migration.

Approved by AJ on 14 September 2026.

Implementation note: with `safeAreaInset(edge: .bottom)` the list scrolls beneath the bar, so the bar takes `.background(.bar)` in addition to the top `Divider`; without a material the plus and minus controls would sit over scrolled rows. `Material.bar` is "a material matching the style of system toolbars." Source: https://developer.apple.com/documentation/SwiftUI/Material/bar

### Q2. Possible latent crash in `MetadataFolderAssignment`

Observed 14 September 2026 while seeding the sidebar preview harness: inserting a `MetadataFolderAssignment` into an in-memory `ModelContainer` crashed inside SwiftData with `Could not cast value of type '_NSCoreDataTaggedObjectID' to 'NSString'`. The model declares a stored property named `objectID` (`Packages/QuorraCore/Sources/QuorraAppLogic/Metadata/MetadataModels.swift`), and `objectID` is also the name of the Core Data managed-object identifier that SwiftData builds on. Inserting `MetadataFolder` and `IMDSEndpointDefinition` the same way works, so the collision is the leading hypothesis. Folder assignment is the only code path that creates this model, and AJ's own store has no folders yet, so the crash may have never been exercised in the app.

Recommendation: reproduce in the running app first (create a folder from the Profiles context menu, drag a profile onto it) before changing anything. If it reproduces, rename the stored property (for example `objectIDString`, matching the file's existing naming) and keep the `objectID` accessor as a computed property so callers do not change; because the attribute name changes, check whether SwiftData's lightweight migration carries the column or whether a `VersionedSchema` step is needed. This is outside the list migration and should be its own change.

Alternative considered: rename now without reproducing. Rejected because the preview host has already shown two preview-only failures today, and a schema change deserves a confirmed reproduction in the app.

Superseded by Q3 if folders are removed: the assignment model goes with them and the crash has nothing left to affect.

### Q3. Remove the folder feature

Asked by AJ on 14 September 2026: folders exist to organise items, the app is pre-v1, and the feature does not look valuable. Inventory (agent sweep, same day): the feature is a leaf. Two SwiftData entities with no relationships to the endpoint and log entities that share the store, two schema lines, `MetadataFolderPicker.swift` (108 lines), `MetadataObjectDragPayload.swift` (16 lines), roughly 300 of the 518 lines in `SessionRailView.swift`, roughly 130 lines in `ProfileListView.swift`, the `.folder` case of `SourceSelection` with seven switches the compiler will point at, three small detail-pane blocks, one 8-line test, no README, CHANGELOG, or docs mention, and one squashed commit (`2368a53`) that introduced all of it. `IMDSEndpointDefinition.folderIDString` has no callers at all.

Recommendation: remove it, as its own change after this migration lands. Approved by AJ on 14 September 2026. It deletes the fragile parts this migration exposed (D6 name identity, the drop target, Q2's model) and leaves the sidebar with four static rows, so D10 and D11 no longer apply there. The store keeps `IMDSEndpointDefinition` and `IMDSEndpointLogEntry`; dropping two entities from an unversioned schema relies on SwiftData's inferred lightweight migration, which Apple documents as handling entity and attribute removal ("Migrating your data model automatically", https://developer.apple.com/documentation/CoreData/migrating-your-data-model-automatically), so the change needs one manual test against a real `default.store` before release. Alternative considered: keep folders and fix Q2. Rejected because it spends a schema change and a migration on a feature with no evidence of demand.

### Q4. What to do about D10

D10 is a macOS 27 platform bug reproduced with nothing but `List`, `Section`, `Text`, and `ForEach`. The code already carries the mitigation (both columns key their `ForEach` by the selection type), and after Q3 the sidebar has no `ForEach` at all. Approved by AJ on 14 September 2026. Recommendation, three small things: file a Feedback Assistant report once a standalone reproducer exists (the same-day attempt, recorded under D10, did not reproduce it, so this is parked); update the "Recommended Sidebar Row Pattern" in `.claude/skills/swiftui-patterns/SKILL.md`, whose example keys by `item.id` and tags by `item.id`, so it says to key the `ForEach` by the selection type and to keep row views with `if` or `switch` bodies in their own file; and add one line to AGENTS.md under Coding Style so people follow the same rule. No further code change. Alternative considered: the `List(_:id:selection:rowContent:)` initializers. Rejected because they carry the same identifier-versus-selection constraint.

## Checklist

- [x] Fable: convert `SourceSidebarView` (D1, D3, D4, D5, D6, D10, D11).
- [x] Fable: build, run, confirm accessibility tree shows list rows with a selected state, sidebar icon size applies, light and dark appearance both render. Arrow keys were re-verified on 15 September 2026 with system-level synthesized input after D13; type-to-select was dropped from scope. Done so far: warning-free build, live app shows `AXOutline` rows with native badges and selection, sidebar icon size applies, preview renders in light with a nested folder row. Still open: folder rows, context menus, and drop in the running app (needs a folder created from the context menu, which needs the screen unlocked), and the dark preview. Closed 14 September 2026: the dark sidebar preview rendered, and the folder checks are moot because Q3 removed folders.
- [x] AJ: answer Q1.
- [x] AJ: decide Q2. Superseded by Q3 on 14 September 2026.
- [x] Opus: convert `ObjectListView` (D2, D5, D8) and its preview harnesses. Done 14 September 2026; the previews only rendered after D12.
- [x] Fable: remove `NavigationRowButtonStyle` (D7).
- [x] Fable: rerun the build and test plan, run the app and check both columns (accessibility rows, selection, light and dark), review the combined diff. Done 14 September 2026: warning-free build, 509 tests passed, both columns are `AXOutline` rows in the running app, clicking an object row drives the detail column, all four previews render in light and the sidebar also in dark.
- [x] AJ: in the running app, try Up and Down arrows in both columns. AJ reported on 15 September 2026 that the arrows moved nothing; see D13 for the cause and the fix. AJ dropped type-to-select from scope the same day and confirmed with the keyboard that the arrows work in both columns after D13.

## Verification

- Build through the Xcode MCP `BuildProject`; the build must stay warning-free.
- Run the app, screenshot each column, and inspect the accessibility summary: rows should no longer appear as plain buttons, and the selected row should carry the selected state.
- Keyboard: Up and Down arrows move the selection in both columns (D13). Type-to-select was dropped from scope by AJ on 15 September 2026.
- System Settings, Appearance, Sidebar icon size: changing it resizes the sidebar rows.
- Xcode previews in both files still render.
- Run the `quorra` test plan through `RunAllTests`.
