<div align="center">

<img src="docs/icon.png" width="128" alt="Horizon Leveler icon" />

# Horizon Leveler

**A native macOS app that levels the horizon in thousands of photos at once.**

It finds the tilt in every photo on your Mac, levels the confident ones for you, and gives you fast, precise tools for the rest. Originals are never touched.

![Before and after](docs/before-after.png)

[![Swift](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](https://swift.org)
[![macOS](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white)](https://www.apple.com/macos)
[![SwiftUI](https://img.shields.io/badge/SwiftUI-AppKit-0D96F6?logo=swift&logoColor=white)](https://developer.apple.com/xcode/swiftui/)
[![Vision](https://img.shields.io/badge/Apple-Vision-000000?logo=apple&logoColor=white)](https://developer.apple.com/documentation/vision/vndetecthorizonrequest)
[![License: MIT](https://img.shields.io/badge/License-MIT-black.svg)](LICENSE)

<br />

### ⬇️ Download

[![Download for macOS](https://img.shields.io/badge/Download-macOS-000000?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/vekaev/horizon-leveler/releases/latest/download/HorizonLeveler-mac.dmg)

<sub>Universal build (Apple Silicon + Intel). Not notarized yet: the first time, right-click the app → **Open**. [All releases →](https://github.com/vekaev/horizon-leveler/releases/latest)</sub>

</div>

---

## ✨ Features

- **Batch first:** open or drop a folder (subfolders included). Every photo is analyzed on-device with Apple Vision; **RAW** (CR3, NEF, ARW, DNG, RAF, …), **JPEG**, **HEIC** and **TIFF** all work.
- **Auto-level the easy ones:** detections above your confidence threshold are leveled automatically. Everything else lands in **Needs review**. Tilts under 0.2° count as already level (both thresholds are sliders).
- **Three decisions per photo:** **Level** (`L`), **Keep as shot** (`K`) for tilts you meant, and **Undecided** (`U`). Select many photos in the grid and decide them in one keystroke.
- **Precise leveling tools:**
  - **Fine lines:** a horizontal line every 8 pt (stronger every 40), drawn dark-under-light so they show on bright sky *and* dark water. Or Thirds / 12 / 24.
  - **Guide line + loupes:** drag a line onto the horizon; two **×5 loupes** magnify its left and right ends, so a 0.1° error is obvious.
  - **Two points:** click the horizon on the left, then on the right. Done.
  - **Draw a line:** drag along anything that should be level, or upright for near-vertical edges like buildings.
  - **Rotation ruler:** drag sideways like the Photos dial, with 0.1° ticks. Hold `⌥` for 0.01° precision.
- **Before / after:** **Overlay** with adjustable transparency, **Side by side**, or **Split** with a draggable divider. Hold `Space` any time to see the original.
- **Always reversible:** every photo has a clickable **history**; `⌘Z` / `⇧⌘Z` work across single and batch edits; **Reset to original** is one click. Decisions are saved, so reopening a folder brings everything back.
- **Export:** leveled copies as **JPEG**, **HEIC** or **16-bit TIFF**, cropped to the largest rectangle with the original aspect ratio (no empty corners), with **EXIF, GPS, IPTC and capture date** kept. Plus a CSV log of every angle.
- **Native and private:** Swift + SwiftUI + Vision + Core Image. No account, no server, nothing uploaded.

## ⌨️ Keyboard shortcuts

**Grid**

| Key | Action |
|-----|--------|
| `L` / `K` / `U` | Level / Keep as shot / Undecided (works on a multi-selection) |
| `←` `→` `↑` `↓` | Move the selection |
| `↩` | Open the photo |
| `⌘A` | Select all |
| `⌘Z` / `⇧⌘Z` | Undo / redo |
| `⌘O` / `⌘E` | Open a folder / export |

**Single photo**

| Key | Action |
|-----|--------|
| `L` / `K` / `U` | Decide, then go to the next photo (toggle in the sidebar) |
| `←` `→` | Previous / next photo |
| `[` `]` | Rotate ±0.1° |
| `⇧[` `⇧]` | Rotate ±1° |
| Click, click | Level through two points (`Esc` cancels) |
| Drag | Level along a drawn line |
| `R` | Back to the detected angle |
| `0` | Reset to original |
| `G` | Cycle line density |
| `T` | Show / hide the guide line |
| `C` | Cycle compare mode |
| `H` | Show / hide the detected horizon |
| `Space` (hold) | Show the original |
| `Esc` | Back to the grid |

## 🚀 Quick start

```bash
brew install xcodegen
scripts/build-app.sh --install   # build → ~/Applications/Horizon Leveler.app → launch
```

1. **Open Folder…** (`⌘O`) or drop a folder on the window.
2. Wait for the analysis, then work through **Needs review** with `L` / `K` / `U`.
3. **Export** (`⌘E`) to `<folder>/leveled/`.

## 📦 Build

```bash
scripts/build-app.sh             # universal app + dist/HorizonLeveler-mac.dmg + dist/leveler-cli
swift scripts/make-icon.swift Resources/AppIcon-1024.png   # redraw the icon
xcodegen generate                # regenerate the Xcode project after adding files
```

## 🔎 Command-line tool

`leveler-cli` uses the same engine, which is handy for checking detection quality on a library before reviewing it:

```bash
leveler-cli analyze ~/Pictures/Iceland        # CSV: file, tilt, correction, confidence
leveler-cli export photo.jpg -2.4 out.jpg     # rotate (counter-clockwise positive) and crop
leveler-cli make-test /tmp/tilted             # synthetic photos with known tilts
```

## 🛠️ Tech stack

**Swift + SwiftUI** (macOS 14+, `@Observable`), **Vision** `VNDetectHorizonRequest` for detection, **ImageIO** for fast orientation-correct previews (including RAW), **Core Image** (`CIRAWFilter`) for full-quality export. The project is generated with **XcodeGen** from `project.yml`.

Angle convention everywhere: degrees, counter-clockwise positive, as seen on screen. A photo's *correction* is the rotation applied; leveling a horizon tilted by `a` takes `-a`.

## 💾 Where your data lives

- **Decisions and history:** a hidden `.horizonleveler.json` inside the photo folder, so the folder carries its own state.
- **Exports:** `<folder>/leveled/` by default (any folder you choose), with `horizon-leveler-log.csv`. Export folders are marked so they're never re-imported.
- **Originals:** never modified.

## 📁 Project structure

```
App/                     # SwiftUI app
  HorizonLevelerApp.swift  # window, menus (Open, Export, Undo/Redo)
  Library.swift            # folder, analysis queue, decisions, undo stack, persistence
  Photo.swift              # per-photo state and edit history
  ContentView.swift        # sidebar filters, grid, thumbnails
  PhotoView.swift          # single-photo editor: lines, guide, loupes, compare, two-point
  ExportView.swift         # export sheet
  Support.swift            # theme, image cache, grid overlay, rotation ruler
Core/                    # shared engine (app + CLI)
  HorizonDetector.swift    # Vision horizon detection
  Geometry.swift           # crop math, line angles
  ImageLoader.swift        # folder scan, RAW-aware previews
  Renderer.swift           # rotate + crop + export with metadata
CLI/main.swift           # leveler-cli
scripts/                 # build-app.sh, make-icon.swift
```

## ⚠️ Known issues

- Vision returns nothing for photos that are already level and for many photos with no visible horizon (forests, interiors). They go to **No tilt found**, where two clicks level them by hand.
- Not notarized yet, so macOS asks for confirmation the first time.

## 🗺️ Roadmap

- [GeoCalib](https://github.com/cvg/geocalib) (Core ML) as a second opinion for low-confidence and no-horizon photos.
- Straight-line detection overlay: click a detected line to level by it.
- XMP sidecars for Lightroom / darktable instead of rendered copies.
- Finder Quick Action: right-click a folder → *Level horizons*.

## 📄 License

[MIT](LICENSE): free to use, modify and share.
