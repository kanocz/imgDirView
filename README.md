# imgDirView

A fast, minimal image viewer for macOS designed to be launched from the terminal — works great with [Midnight Commander](https://midnight-commander.org/) and other file managers.

## Features

- **Instant open** — pass a filename, the image appears immediately
- **Directory navigation** — browse all images in the same folder with ← / → arrow keys
- **Background preloading** — next and previous images are loaded in the background for instant switching
- **Fit-to-window by default** — every image opens scaled to fit, with a status bar showing the zoom level
- **Zoom** — `+` / `-` keys or trackpad pinch; `f` returns to fit-to-window; `o` resets to 1:1 pixels
- **Pan** — drag with the mouse when zoomed in, or use `Shift` + arrow keys
- **Delete** — `Backspace` / `Delete` moves the current file to Trash (with confirmation); falls back to permanent delete for network drives
- **Dual keyboard input** — reads keys both from the GUI window and directly from the terminal stdin, so all shortcuts work even if the terminal stays focused after launch (no need to click the window)
- **Robust filesystem support** — handles Cyrillic and Unicode filenames correctly on local HFS+, NFS, and other network filesystems

## Supported formats

`JPEG · PNG · GIF · BMP · TIFF · HEIC · HEIF · WebP · AVIF · ICO · PNM/PGM/PPM`

## Keyboard shortcuts

| Key | Action |
|-----|--------|
| `Esc` | Quit |
| `←` / `→` | Previous / next image |
| `+` or `=` | Zoom in |
| `-` | Zoom out |
| `f` (or `а`) | Fit to window |
| `o` (or `щ`) | Reset to 1:1 (original size) |
| `Shift` + arrows | Pan the image |
| `Backspace` / `Delete` | Move current file to Trash |
| `Cmd+Q` | Quit |

Keys in parentheses are their Russian-layout equivalents — the same physical key works regardless of which keyboard layout is active.

## Mouse

| Action | Result |
|--------|--------|
| Drag | Pan (when zoomed in) |
| Pinch | Zoom in/out |

## Installation

### Build from source

Requirements: Xcode Command Line Tools (`xcode-select --install`) or full Xcode.

```bash
git clone https://github.com/yourname/imgDirView.git
cd imgDirView
swift build -c release
cp .build/release/imgDirView /usr/local/bin/
```

### Usage

```bash
imgDirView photo.jpg
imgDirView /path/to/image.png
imgDirView "Фото с отпуска.heic"   # Unicode filenames work fine
```

### Midnight Commander integration

Add this to `~/.config/mc/mc.ext` (or `~/.mc/bindings`) to open images with imgDirView:

```
shell/.jpg
    Open=imgDirView %f

shell/.jpeg
    Open=imgDirView %f

shell/.png
    Open=imgDirView %f

shell/.heic
    Open=imgDirView %f
```

Or press `F3` on any image file and configure imgDirView as the viewer in MC settings.

## Filesystem and Unicode compatibility

### The problem with macOS path APIs

macOS stores filenames on HFS+/APFS in a custom variant of Unicode NFD (Decomposed Normal Form).
For example, the Cyrillic letter **й** (U+0439) is stored as two code points: **и** (U+0438) + combining breve (U+0306).

Most macOS path APIs — `FileManager`, `NSString`, `URL.withUnsafeFileSystemRepresentation` — automatically apply this NFD normalisation before passing paths to the kernel. On local disks this is harmless because HFS+/APFS expects NFD. But on **NFS mounts** and other network filesystems, filenames are stored in whatever encoding the server uses (typically NFC — Composed Normal Form). When a macOS API normalises a path to NFD and the NFS server only knows the NFC form, the kernel returns **ENOENT** (file not found) even though the file is perfectly accessible.

### What imgDirView does differently

imgDirView avoids all Foundation/Cocoa path handling for filesystem operations:

- **Path argument** — the raw command-line string is passed through as a plain Swift `String` without any conversion. Swift strings preserve the original byte sequence (NFC) from the shell.
- **Directory scanning** — uses POSIX `opendir()` / `readdir()` called via `String.withCString {}`, which sends the exact UTF-8 bytes the kernel originally returned. Foundation's `FileManager.enumerator` is not used.
- **Image reading** — uses POSIX `open()` + `read()` via `String.withCString {}`. `Data(contentsOf:)` and `NSImage(contentsOf:)` are not used.
- **Existence check** — uses `Darwin.open()` instead of `FileManager.fileExists()`, which uses `stat()` through Foundation (NFD-normalised, fails on NFS).

`URL` objects are still used for AppKit display (window title, status bar), where Unicode normalisation is harmless.

## Terminal keyboard input

When imgDirView is launched from a terminal (MC, iTerm2, etc.), macOS may not automatically transfer keyboard focus to the new window — the terminal emulator stays active and receives keystrokes. To work around this, imgDirView reads keys from **two sources simultaneously**:

1. **GUI event monitor** — standard AppKit `NSEvent` local monitor. Works when the imgDirView window is the active, focused application.
2. **stdin in raw mode** — imgDirView puts the inherited terminal file descriptor into raw (non-canonical) mode and watches it with a `DispatchSource`. Keypresses typed in the terminal are delivered here even if the GUI window never received focus.

Both sources trigger the same actions. Whichever fires first wins; there is no double-processing because the two inputs are independent channels. When imgDirView exits, the terminal is restored to its original settings automatically.

This means you can launch imgDirView from MC and immediately start pressing `←` / `→` to browse — no need to click the viewer window first.

## Project structure

```
Sources/imgDirView/
├── main.swift                  Entry point — argument parsing, POSIX existence check
├── AppDelegate.swift           NSApplication lifecycle
├── ImageWindowController.swift Window, keyboard handling, status bar, delete confirmation
├── ZoomableImageView.swift     Custom NSView: draw, zoom, pan, pinch
├── ImageNavigator.swift        POSIX directory scan, file list, background preloading
└── TerminalKeyReader.swift     Raw stdin key reading — works without GUI focus
```

## Requirements

- macOS 12 Monterey or later
- Apple Silicon or Intel

## License

MIT
