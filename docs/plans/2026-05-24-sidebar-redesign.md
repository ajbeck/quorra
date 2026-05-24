# Sidebar Redesign — Implementation Plan

_Date: 2026-05-24 · Status: implemented (build green, unit tests pass, previews verified; app-level interaction pass pending user ⌘R)_

## Context

The sidebar (`App/Views/SidebarView.swift`) is being redesigned from a hierarchical 3-section `List` (SSO Sessions with `DisclosureGroup`s → Long-term keys → Other) into a **segmented, flat, profile-first** layout, per the Claude Design handoff (`Sidebar.html` → `sidebar-explorations.jsx`, Round 3 "winner"). The driving product insight from the design chat: _"the individual profile is the primary entry point; the SSO session is a consequence of the profile."_ So sessions stop being parents and move to their own tab.

This plan was produced by walking the full design tree one decision at a time, under the project's **Native First** build philosophy (CLAUDE.md): reach for the out-of-the-box control first; build custom only where the stock control demonstrably falls short; for every element, state how far native gets us and what fidelity we forfeit.

## Resolved architecture

`MainView`'s two-column `NavigationSplitView { SidebarView(selection:) } detail: { DetailView(selection:) }` and the `SidebarSelection`/`DetailView` routing are **unchanged**. The redesign is contained to the sidebar column:

- a native segmented `Picker` (Profiles | SSO Sessions) pinned above
- a single custom scroll/selection container that swaps between a flat **Profiles** list and a flat **SSO Sessions** list
- native `.searchable(placement: .sidebar)` filtering the active tab

The first pass targeted `List(.listStyle(.sidebar))`, but SwiftUI's macOS `NSOutlineView` bridge repeatedly crashed in previews with custom rows. The implemented version keeps native split-view/search/segmented controls, but uses a custom `ScrollView` + `LazyVStack` row container for the sidebar rows. Row content (profile row, colored `via` badge, session row) and the badge color system remain custom.

## Decisions

| # | Decision | Rationale / source |
|---|----------|--------------------|
| 1 | **Custom row container inside the native sidebar column** after first trying `List(.sidebar)` | Native First still applies: the first implementation used native `List`, but SwiftUI's macOS outline-list bridge crashed in previews with custom rows. The custom container is scoped to rows only; split view, search, picker, and detail routing remain native. |
| 2 | **Native segmented `Picker`** (Profiles \| SSO Sessions) pinned atop the sidebar; swaps the List content | Round-3 winner. HIG _Segmented controls_: appropriate for "different views of the same data"; 2 segments is within the 2–5 guidance. Native ≈85–90% (loses the mockup's glowing pip — see #11). |
| 3 | **Single uninterrupted flat Profiles list** (no section dividers) | Honors profile-first intent; `via` badge + filter replace section headers. Both options are native — this is a design-intent choice, not a fidelity gap. |
| 4 | **Native `.searchable(text:placement:.sidebar, prompt:)`** on the split view; scopes to active tab; prompt adapts | Doc-confirmed: `SearchFieldPlacement.sidebar` renders a sticky search header in the sidebar on macOS. Native ≈90% (cede exact search-vs-picker vertical order to the system — accepted; search above picker is fine). |
| 5 | **2-line profile row** (native `List` row, the skill's _Recommended Sidebar Row Pattern_): `ProfileStatusIcon` + name (line 1) + `via` badge (line 2). **Account/role are NOT shown in the sidebar** — they live in the detail pane. | REVISED 2026-05-24 after consulting `.claude/skills/swiftui-patterns`, which lists 3+ text lines and inline-metadata strips as anti-patterns and recommends exactly one icon + title + one secondary line. Account/role are often redundant across SSO profiles (same account/role); the user-chosen name + `via` badge carry identity + disambiguation. HIG _Lists and tables_: "small image + brief explanatory label." Supersedes the earlier 3-line decision. |
| 6 | **Status glyph reuses the shipped vocabulary** — `ProfileStatusIcon`/`SessionStatusIcon`: filled SF Symbol, `.green` active / `.red` needs-action / `.secondary` inert, shape-primary per HIG Inclusive Color, motion for in-flight. **Cyan stays the tint/selection color; green = active.** The mockup's cyan-pip/colored-dot is rejected. | Reuse "what we've already done" (D4/D31). Avoids a competing color language. |
| 7a | **Per-session colored `via` badge now** (not deferred) | User chose to "lean into" the brand; color aids session clustering. Badge view is ~100% native. |
| 7b | **Palette + assignment:** 6-hue cool→magenta palette (indigo ≈265, blue ≈250, purple ≈290, violet ≈310, magenta ≈335, pink ≈350), explicitly **avoiding green ≈150 / red ≈25 / amber ≈70 / cyan ≈220**. Deterministic `hash(sessionName) → index`, no persistence. **SSO sessions colored; long-term/other neutral gray.** Asset-catalog colorsets with light+dark appearances; saturated fg + ~16% bg + swatch dot | Collision-safe with the semantic + selection colors. Rule: _color = which SSO org; neutral = standalone creds._ Finder-tags precedent for colored list items. |
| 8 | **Sort: `default`-first, then alphabetical** (existing `profileSortOrder`, ProfilesModel.swift:223) | `last-used` isn't tracked (not faked). Profile-first; filter handles findability. Rejected session-clustering (rebuilds the flattened grouping). One-line comparator swap to iterate. |
| 9 | **SSO Sessions tab = flat session rows** (no nested profiles). 2-line: `SessionStatusIcon` + name + **live countdown** / "N profiles · region". Selecting routes to existing `SessionDetailView` | Round-3 "session tab shows just the session rows." See validated formatting API below. |
| 10 | **Single shared `SidebarSelection` drives detail** (routing unchanged). `activeTab` = `@State` in `SidebarView`. Selection persists across manual tab switches; unmatched selection simply isn't highlighted. `onChange(of: selection)` auto-switches tab when selection **kind** changes (so detail-pane cross-links land on the right tab). Launch default = Profiles; `@SceneStorage` persistence deferred | HIG _Lists and tables_: persistently highlight the selected row for navigation. Decouples "visible tab" from "what's selected." |
| 11 | **Segment labels carry trailing counts**; **no in-segment live-pip for v1**. States via `ContentUnavailableView` (failed / empty-tab / `.search` no-match); idle/loading → `ProgressView` with picker+search **hidden** until loaded. Semantic + asset-catalog colors → light/dark/system automatic | Native segmented labels render monochrome → a glowing pip can't live inside a segment; the live signal stays on the session rows (green `key.icloud`). See HIG caveat on counts below. |

## HIG & API validation (via Xcode MCP DocumentationSearch)

Verified against current Apple documentation. Conformant unless noted.

- **`PickerStyle.segmented`** — "Use when there are two to five options." We have 2. ✓ HIG _Segmented controls › Best practices_: closely-related views of data; keep control types consistent (ours is pure selection). ✓
- **`SearchFieldPlacement.sidebar`** — "In macOS the search field appears as a sticky header in the sidebar, attached to the toolbar." ✓ (matches #4).
- **`ContentUnavailableView`** + `.search` / `.search(text:)` — confirmed current; idiomatic via `.overlay`. ✓ (already used elsewhere in the app's `DetailView`).
- **`onChange(of:initial:_:)`** — current signature is the zero- or two-parameter `(old, new)` closure (macOS 14+). ✓ (not the deprecated single-param form).
- **HIG _Lists and tables_** — "prefer text in a list"; "persistently highlight the selected row" for navigation. ✓ (rows are text-forward; selection is persistent).
- **HIG _Sidebars_** — "no more than two levels of hierarchy." Flattening to tabs keeps the sidebar at **one** level — *more* conformant than the prior nested-disclosure design. ✓

### Adjustment A — live countdown formatting (decision #9)

Use the **modern Foundation API**, not `DateComponentsFormatter`:

```swift
TimelineView(.everyMinute) { _ in
    // remaining
    let remaining = Duration.seconds(max(0, expiresAt.timeIntervalSinceNow))
    Text(remaining.formatted(.units(allowed: [.hours, .minutes],
                                    width: .abbreviated,
                                    maximumUnitCount: 2)) + " left")  // "6h 12m left"
}
```

- `TimelineView(.everyMinute)` is the idiomatic minute-cadence schedule (not `.periodic(from:by:60)`).
- `Duration.UnitsFormatStyle` (`.formatted(.units(allowed:width:.abbreviated))`) is the current way to render "6h 12m"; `DateComponentsFormatter` is the older API.
- Expired state → `Date.RelativeFormatStyle` ("2d ago").

### Adjustment B — counts inside segments (decision #11)

HIG _Segmented controls › Content_: "Use nouns or noun phrases for segment labels… title-style capitalization," and "use content with a similar size in each segment." A trailing count (`Profiles 7`) is a **mild deviation** — it's a noun phrase plus a number, and counts of differing widths can unbalance equal-width segments.

**Resolution:** keep counts for v1 but treat them as a **validate-visually** point. If they look unbalanced/non-idiomatic in the prototype, the fallback is to drop counts from the segments (the lists are short and self-evident) or surface counts elsewhere. Not a blocker; flagged honestly.

## Component inventory

**Reuse as-is:** `ProfileStatusIcon`, `SessionStatusIcon`, `SidebarSelection`, `DetailView`, `ProfileDetailView`, `SessionDetailView`, `ProfilesModel.groups` + `profileSortOrder`.

**Build / rewrite:**
1. Badge color system — asset-catalog colorsets (6 hues + neutral, light+dark); `hash(sessionName)→hue`; `ViaBadge` view (swatch + label; colored for SSO, neutral for long-term/other).
2. Profile `kind` + `via`-label helper — derive kind/label from the existing bucket (SSO → session name, colored; long-term/other → neutral label). No ARN parser / coordinate resolver (account/role dropped from the row per revised #5).
3. `ProfileRow` rewrite — 3-line, variable height; keep status `.task`.
4. `SessionRow` rewrite — 2-line + `TimelineView(.everyMinute)` live countdown (Adjustment A); keep status `.task`.
5. `SidebarView` restructure — `activeTab` `@State`; segmented `Picker` w/ counts (loaded only); custom scroll/selection rows swap per tab; `onChange(of:selection)` tab sync.
6. Filter wiring — `.searchable(placement:.sidebar)`, prompt per tab, filters active list.
7. States — `ProgressView` (idle/loading); `ContentUnavailableView` failed / empty / `.search`.

## Build sequence (each phase independently verifiable)

1. **Badge system** → `ViaBadge` previews (all hues, long-term/other, light+dark).
2. **Kind/via-label helper** (from bucket) → Swift Testing unit tests (kind + label per bucket; stable hash → palette index). _Strongest test target._
3. **`ProfileRow`** → previews for every kind × status.
4. **`SessionRow`** → previews for signedIn/expired/signedOut/signingIn + live countdown.
5. **`SidebarView`** → previews: populated, empty, loading, failed, filtered-no-match; tab switching; selection sync.
6. **Build + render** via Xcode MCP (`BuildProject`, `RenderPreview`). App-level `⌘R` verification is the user's (agent can't drive the running app).

## Prototype-verify risks (flagged, not assumed)

- `.searchable(.sidebar)` exact ordering/behavior when a `Picker` also sits in the sidebar (fallback: lift `filterText` to `MainView`, or inline field).
- Segmented `Picker` with text counts rendering cleanly on Tahoe (Adjustment B).
- Custom selected rows matching sidebar expectations closely enough in app-level interaction.

## Deferred (iterate-later)

Tab-level live-pip (would need a custom segmented control), `@SceneStorage` last-tab persistence, user-assignable badge colors, session-clustered sort, `last-used` data tracking.
