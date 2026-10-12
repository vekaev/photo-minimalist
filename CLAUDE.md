# Photo Minimalist (formerly Horizon Leveler): working rules

**Preview, level, crop. Nothing else.** A minimalist photo previewer for Mac and iPhone with horizon leveling and crop. Keep it that small.

Two apps share one engine:

| | Mac | iPhone / iPad |
|---|---|---|
| UI code | `App/` (except `Photo.swift`, `Library.swift`) | `iOS/` |
| Shared model | `App/Photo.swift`, `App/Library.swift` | same files |
| Engine | `Core/` | same files |
| Scheme | `HorizonLeveler` | `HorizonLeveler-iOS` |

## Rule: every change ships on both platforms

The owner should never have to ask twice. For **any** feature, fix or design change:

1. **Make a task list with two sides before writing code**: one task for Mac, one for iPhone (or iPad), plus one for shared model/engine work if any. Track it with the task tool.
2. **Translate, don't copy**: the same intent, adapted to the platform.
   - keyboard shortcut ↔ gesture or button
   - right-click / two-finger click ↔ long-press context menu
   - hover / tooltip ↔ visible hint
   - side-by-side panes ↔ full-screen views
3. **If something truly doesn't apply** to one platform, say so in the reply ("iPhone: not applicable, because …") and record it in the parity table below. Never skip it silently.
4. **Build both schemes** before saying it's done:
   ```bash
   xcodegen generate
   xcodebuild -project HorizonLeveler.xcodeproj -scheme HorizonLeveler -configuration Debug -derivedDataPath build -quiet build
   xcodebuild -project HorizonLeveler.xcodeproj -scheme HorizonLeveler-iOS -configuration Debug -destination "platform=iOS Simulator,name=iPhone 17 Pro" -derivedDataPath build -quiet build
   ```
5. **Check both**: iPhone in the simulator (screenshots), Mac via the build plus anything testable without touching the owner's open app and real photos. Report what was and wasn't seen on screen.
6. **Restart both apps with the new build when a change is done** (the owner asked for this; no need to ask each time):
   ```bash
   scripts/install-mac.sh                    # builds, quits the running copy normally (state is saved), installs, reopens
   scripts/run-ios-sim.sh Documents/Iceland  # rebuilds and relaunches the iPhone app in the simulator
   ```
7. **Update the parity table** below and the README.

## Design

Minimal, monochrome, Notion / Apple-like on both platforms: no colored badges, no title bar or big headers (on the Mac the folder name is its tab in the thin top bar; the list header is just the filter tabs), extras behind one "⋯" (or the view menu). Light and dark follow the system.

Detections are **suggestions only**. Never level a photo the owner didn't decide on (Vision reports ~100% confidence even when it's wrong).

## Parity table

| Feature | Mac | iPhone |
|---|---|---|
| After Level / Keep: stay on the photo and show the result (default); "next photo after a decision" is an opt-in setting. A plain click in the full-width list opens the preview | ✓ (Settings ▸ Review) | ✓ (settings sheet); the editor no longer closes itself |
| Open folder | ⌘O (several at once), drop folder | Files picker |
| Several folders open | our own tab strip in a 38 pt top bar above sidebar + preview (`App/FolderWindows.swift`: `FolderTabs` per window, one Library per tab, `TopBar`; native window tabbing is off; menus use the selected tab via `@FocusedValue(\.library)` / `\.folderTabs`). Bar: ◨ preview toggle · square tabs (× on hover, middle-click closes, drag to reorder) · + (folder picker into a new tab, or this one if empty) · “checking n of N” · ⋯. ⌘T new tab, ⌘W closes the tab (saved; the last tab becomes the start page), ⇧⌘W closes the window, ⌘1…9, ⌃Tab / ⌃⇧Tab, ⌘⇧] / ⌘⇧[. ⌘O / drop / card "Open" use this tab if empty else a new tab; an already-open folder just selects its tab; eject closes the card's tabs. Window buttons are re-centred in the taller bar (`TrafficLights`); empty bar drags / double-click zooms (`WindowDragArea`) | no tabs (no room): last 5 folders as security-scoped bookmarks (`iOS/RecentFolders.swift`): "Recent" on the start screen, ⋯ → "Switch folder" (saves the current folder first) |
| Crop: Original/Free/1:1/4:5/3:2/16:9 (flip ⟲), corners/edges/move, with leveling; in thumbnails, export, save, copy, history | C or crop button, ↵ / Esc | crop button, Done / Reset |
| RAW + JPEG pairs shown as one (the JPEG), "+ RAF" tag | ✓ list + grid, setting in panel | ✓ grid + peek, setting in sheet |
| Tabs: All · Tilted (confident tilt, undecided; enum case `.review`) · Edited (leveled or cropped) · ♥. Keep as shot just leaves Suggested; no Kept tab | ✓ | ✓ |
| Favorites (♥ in `.horizonleveler.json`; Mac also sets Finder's Red tag on the file + RAW twin, and imports Red-tagged files on open) | F, ♥ in the preview, right-click, red heart on tiles/rows | ♥ in the editor, long-press, heart on cells; no Finder tags (iOS has no tag API for files) |
| Apple Photos via PhotoKit (Photos ignores Finder tags/XMP): add originals (RAW as alternate, favorites stay favorites); mark favorites on copies already imported (name + date match, only sets) | ⋯ → Apple Photos, right-click "Add to Photos", export sheet | ⋯ → Apple Photos, long-press "Add to Photos" |
| Suggestion: only confident tilts (`Detection.isConfident`: Vision + lines agree within 1° and 0.5…8°, or no Vision + lines strength ≥ 0.75 and 0.5…1.5°; ~17 % of the owner's card), never auto-applied. Quiet default view: a corner chip "Tilted 1.4° · Level", then "Leveled · Undo" for 4 s (`Library.quickLevel` / `undoQuickLevel`) | chip top-right in the photo: hover = leveled preview + dashed line, click or L levels; K dismisses | chip: tap levels, long-press previews while held |
| Two detectors (Vision horizon + straight lines), combined; re-check on detector version bump | ✓ shared | ✓ shared |
| Review order: shot order (default) or biggest tilts first (setting; no headings) | ✓ ⋯ menu + settings | ✓ bottom panel |
| Fast previews (JPEG thumbnail for lists, RAF preview, disk cache, memory cap) | ✓ shared | ✓ shared |
| On-screen thumbnails read before the background check (ReadGate); check saves grid thumbnails | ✓ shared | ✓ shared |
| Equal tiles: whole photo fitted (Lightroom-style) or cropped to fill (setting) | ✓ default fit | ✓ default fill (like Photos) |
| Photo-only tiles with tags (confident tilt pill "1.4°", ✓ leveled, Kept, RAF) | ✓ name on hover / select | ✓ name in long-press preview |
| Memory card inserted → Ask / Open / Nothing; eject closes the folder | ✓ | n/a: iOS doesn't report card insertion |
| Reopen last folder at launch (setting) | ✓ all open tabs (`openFolders` in tab order, `activeFolder` selected; `lastFolder` still written; missing paths skipped) | ✓ the last folder |
| Level tool (`Library.levelTool`, like crop mode): headline, As shot \| Leveled switch, ruler, dashed line, guide + loupes, two-point picker; stays open across photos | R, level button next to crop, Photo menu "Level Tool"; ↵ / Esc done (Esc clears a pick first) | level button next to crop; Done. Trash moved to the settings button's long-press + settings sheet |
| Level / Keep / Undecided (decision switch in the level tool; decided photos show "Leveled −1.3°" / "Cropped 4:5" quietly) | L / K / U, switch; status text in the top row | switch, long-press menu |
| Change status from the list or grid | right-click | long-press |
| Photo list + optional preview | ✓ (preview can be hidden) | n/a: no room; grid → full-screen editor |
| Photo info (`Core/PhotoInfo.swift`: date taken, camera · lens, focal (35 mm eq.), aperture, shutter, ISO, pixels, file + RAW size, orientation; header-only read, `Photo.info` cached in the json; read lazily for visible rows/tiles via the ReadGate (`Library.fillInfo`, `Shared/PhotoDetails.swift`) and during the background check when it opens the JPEG itself, i.e. no RAW twin) | full-width list (preview hidden): Finder-like columns Date taken · Camera · lens · Exposure · Size · Edits with a header, dropping out as the window narrows (`App/PhotoInfoViews.swift`); with the preview: one extra line under the status; preview: Info card bottom-left (I or ⓘ in the top row). No column sorting (the list order is the review order) | editor: tap the "3 / 120 ⓘ" counter for a details sheet (no room for another icon); long-press peek: date + exposure line under the name; grid cells read info after their thumbnail |
| Quick look (grid only; arrows move like the grid, ↑↓ by a row) | Space in the grid: floating card, fade + gentle scale (≈0.25 s), opens with the cached image | long-press: floating preview + status menu |
| Opening a photo | preview pane / quick look | zoom out of the tile (iOS 18+), opens with the cached image |
| Full-window editing | the preview pane | tap a photo |
| Customizable control bar (`Shared/PhotoControls.swift`: `PhotoControl` catalogue (id, title, symbol, shortcut hint); actions run through each view's existing functions, shortcuts work whether or not a control is shown). Overflow goes into a trailing menu, never wraps | preview top row (`PhotoView.controlBar`), `photoControls` (default Level, Crop, Favorite, Original ⇄ result, Info, History, View options) + `photoControlsLabels` (icon only by default). Right-click the row, ⋯ ▸ or View ▸ "Customize Controls…" → Finder-like sheet (`App/ControlBar.swift`): drag to reorder, − / drag out, + / drag in, Show labels, Restore Defaults. Overflow: "»" menu (measured width; the name keeps its room) | Settings sheet ▸ "Editor buttons": toggles + Edit to reorder, `ios.photoControls` (default eye, ♥, undo, crop, level). Close, the counter (= Info) and Settings always stay; overflow → ⋯ in the top bar. Not on iPhone: Compare (missing), Export (folder-wide from the grid), Info / View options (fixed) |
| Settings | side panel (S or sliders button), slides in/out | bottom panel (sliders button), swipe down to close: Level (suggested horizon, guide) · View (lines, fill) · This photo (… History, Move to Trash) · General · Review order · Appearance last. No loupes toggle (iPhone has no loupes) |
| Appearance: System / Light / Dark | Settings ▸ Appearance (whole app via NSApp.appearance) | Settings ▸ Appearance (preferredColorScheme) |
| See the original ⇄ result | Space in the preview (toggle), hold M | tap the eye (toggle) |
| Two-point leveling, Notes-style: thin line, magnifier while holding, two magnifiers after, drag ends to fine-tune, confirm to apply (level tool only) | ✓ (↵ / Esc); clicking the photo does nothing outside the tool | ✓ (button); outside the tool swipes always change photos |
| Draw a line | replaced by the two-point picker (press, drag, release = one end) | same |
| Rotation ruler (level tool) | ✓ (⌥ for fine) | ✓ (haptics) |
| Fine lines / thirds | ✓ (+12 / 24) | ✓ |
| Guide line | ✓ | ✓ |
| Loupes on the guide | ✓ | **missing** |
| Compare overlay / side by side / split | ✓ | **missing** (hold for original only) |
| History with jump-back (per photo) | ✓ popover (clock button), "Show all activity…" at its bottom | **missing** (undo only; the folder History below has "This photo") |
| Folder activity history ("git log"): append-only `.horizonleveler-history.jsonl` in the folder (read-only card → `Application Support/HorizonLeveler/history/<sha256 of path>.jsonl`), one JSON line per action (decisions, corrections, crop + versions, ♥, delete / put back, save / restore original, Photos, export, undo / redo, revert), written off the main thread from `Library` (`Shared/Journal.swift`, extension at the end of `App/Library.swift`), read newest-first a page at a time. Revert = new undoable step back to the entry's `before` (warns if the photo changed later); delete → files back from the Trash ("Already emptied from the Trash" otherwise); save to original → restore original; Photos / export not revertible | View ▸ History (⌘Y): sheet 520×640 (`Shared/ActivityView.swift`), by day, search, "Only this photo", hover Revert / Show, right-click | ⋯ ▸ History (grid) and editor settings ▸ History ("This photo"): sheet, search, swipe-left Revert, tap = show photo |
| Undo / redo | ⌘Z / ⇧⌘Z | undo button |
| Multi-selection (decide / ♥ / copy / delete act on all selected) | list + grid: ⌘-click toggle, ⇧-click range, ⌘A; the opened photo stays the single "current" one | grid "Select" mode: tap to check, bottom bar Favorite / Level / Delete / Done |
| Move to Trash (file + RAW twin, `trashItem`; backups untouched; never a permanent delete) and undo (files moved back, photo reinserted with its edits, reselected; taken path or missing file → skipped + toast) | Delete / ⌘⌫ in list, grid, preview; right-click; NSAlert with "Don't ask again"; ⌘Z | long-press "Delete", editor trash button, Select bar; dialog with "Don't ask again"; toast "Moved 3 to the Trash · Undo" (5 s) + editor undo; no Trash on the provider → hidden `.horizonleveler-trash/` |
| "Ask before deleting" (`confirmDelete`) | settings panel | settings sheet |
| Drag the dashed suggested horizon up/down (level tool) (keeps its angle; resets per photo; double-click/tap resets) | ↕ pointer within ~6 pt, only while no pick is in progress | ~44 pt grab band; taps still go to the picker, a drag starting on the line wins over swipe |
| Guide line: double-click / double-tap puts it back in the middle | ✓ | ✓ |
| Crop versions (`Photo.cropVersions`, `chosenVersionID` in the json): "+ Version", strip of final-crop thumbnails (click = load into the frame, ✓ = in use, delete), Compare survey (equal-height contact sheet) to choose → applied crop, in history | V, ⇧C (also outside crop mode), 1–9 / click in Compare, right-click to delete, Esc | buttons, tap in Compare, long-press to delete |
| "Photos with crop versions" (≥ 2) collection (`Filter.crops`, not a tab) | ⋯ menu toggle | ⋯ menu |
| Save to original (backup in `.horizonleveler-originals/`, renders from the untouched file; RAW stays) | ⌘S, right-click, export sheet "Replace originals" | long-press, editor panel, ⋯ "Replace originals…" (confirm) |
| Restore original from backup | Edit menu, right-click | long-press, editor panel |
| Copy as shown (leveled render) / original / RAW file | ⌘C / ⌥⌘C / ⇧⌘C, right-click | long-press, editor panel |
| Export leveled copies | JPEG / HEIC / TIFF, choose folder | JPEG into `leveled/` |
| Film scan fixes (hidden, owner's Leica M6 shutter bands): gate `labFixes` (@AppStorage, off) hides every menu / button / panel; engine `Core/BandFixer.swift`, screen cache `Shared/BandFixStore.swift` (one analysis per photo from the full file, gain applied to previews / thumbnails, fixed images cached per photo + size + settings). `Snapshot.bandFix` (in history, undo, journal action `bandFix`, `JournalState.band`), `hasEdits`, Edited tab; applied before leveling / crop in `EditedImage(fix:)`, export, copy, Save to Original (`Photo.savedBandFix` re-applied from the backup). `Library.applyBandFix` (batch, toast "Fixed bands on 12 of 20 (8 clean)", clean photos get nothing) / `removeBandFix` / `setBandFix` / `openFixes` | Settings ▸ Advanced. Right-click ▸ Fixes ▸ Remove Shutter Bands (auto) / Remove Fix / Open Fixes Panel; ⋯ ▸ Fixes…, "»" menu, optional control "Fixes" (not a default). Fixes mode in the preview (`App/FixesPanel.swift`, `library.fixesTool`): photo as shot, 300 pt panel with per-side status, strengths, flatten, zones, tilt, force, Before / After / Split (drag handle), zone lines, drag rows + Auto Rows, profile chart, Apply to N selected, Reset / Remove / Apply, Done / Esc. Changes live (50 ms debounce), stored on release | n/a by the owner's choice (Mac-only tool). The iPhone only *shows* fixes made on the Mac (`p.bandFixSource` in the editor and thumbnails); no toggle, menus or sheet |

## Simulator

- Always pass the device to the simulator control tool (`device: "03B18753-A9C9-4A8C-9ADC-3BA0FB353BA7"`, the booted "iPhone 17 Pro"). Without it, it can pick the owner's other project's simulator ("DayGate Test").

## Debugging

- Logs use the `app.horizonleveler` subsystem. In this shell `log` is shadowed, so use the full path:
  `/usr/bin/log show --last 2m --info --style compact --predicate 'subsystem == "app.horizonleveler"'`
- `App/DebugLog.swift` has `WindowProbe()` (window moves/resizes) and `.logSize("name")` (view size changes) for layout bugs. Add them, reproduce, read the log, then remove the calls.
- The preview shows only the final result (rotated, then cropped to fill). No dimmed tilted edges.
- Names: the app is "Photo Minimalist" (iPhone home screen: "Minimalist"). Bundle IDs stay `app.horizonleveler.*` so settings carry over; folders, scheme and CLI still use the old name.
- Never put `.onTapGesture(count: 2)` next to `.onTapGesture`: SwiftUI then delays every single click by the double-click interval. Use one tap gesture and `NSApp.currentEvent?.clickCount`.
- Lessons: an `.inspector` with `inspectorColumnWidth(min:ideal:max:)` snaps back to `ideal` whenever its content redraws, so use a fixed width. On the Mac, restore the last folder from the saved path; the bookmark can lag behind.

## Performance notes (measured on a SanDisk Extreme PRO in the MacBook's built-in reader)

- Card reads ~88 MB/s; Fuji JPEGs ~21 MB, RAFs ~83 MB. Anything that reads whole files is slow.
- Per photo: full JPEG decode 264–404 ms; RAF embedded preview 111–143 ms; JPEG embedded thumbnail 4 ms.
- Over 5° is never "likely": those were portraits / deliberate angles on the owner's card.
- So: list thumbnails use the JPEG's embedded thumbnail, analysis and big previews use the RAF preview, thumbnails are cached on disk, and analysis runs 3 at a time on removable drives.
