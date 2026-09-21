# DWIM: do what I mean, in any Mac app

Tap a key, type what you want in your own words, and DWIM finds and runs the right menu item in whatever app is in front.

> "cut out the background of this photo" → Format › Image › Remove Background
> "put these files in a folder" → File › New Folder with Selection
> "add pages from another pdf into this one" → Edit › Insert › Page from File…

It works in any app with a standard Mac menu bar, with no per-app setup. macOS already exposes every app's full menu tree through the accessibility API; DWIM reads it, asks [Jev](https://typesafe.ai) (TypeSafe's decision model) one yes/no question per menu item, all in parallel, and presses the winner. Jev answers in a few hundred milliseconds, which is what makes this usable while you type.

<!-- demo gif here -->

## Requirements

- macOS 13 or later, with the Xcode command line tools (`xcode-select --install`)
- **Your own Jev API key.** DWIM does not ship with one and has no server. Jev is in early access: request a key at [typesafe.ai](https://typesafe.ai). A query costs a fraction of a cent on your key.

## Install

```bash
git clone https://github.com/rohit9mehta/dwim.git
cd dwim/app
./build.sh
open DWIM.app
```

Because you build it yourself, macOS does not show the "unidentified developer" warning.

On first launch:

1. Paste your Jev key when asked (or later: menu-bar icon **⌘?** → *Set Jev API key…*). It is saved to `~/.config/dwim/env`, readable only by you. You can also set `TYPESAFE_API_KEY` in the environment instead.
2. Allow DWIM under System Settings → Privacy & Security → Accessibility, then quit and reopen it. It needs this to read and press menu items.

## Use

1. Click into any app.
2. Tap **Right Option** (changeable from the menu-bar icon).
3. Type what you want and pause. If Jev is confident, it runs. If not, a short list appears: ↑↓ to choose, ↩ to run, esc to close.

Menu items whose names suggest data loss (delete, erase, empty, revert, remove, quit…) never run on their own; they always wait for ↩.

## Settings

Click **⌘?** in the menu bar: trigger key, automatic running, API key. Two thresholds can be tuned from the terminal:

```bash
defaults write com.rohitm.dwim confident -float 0.7   # minimum confidence to run without asking (default 0.5)
defaults write com.rohitm.dwim lead -float 0.15       # how far ahead of the runner-up it must be (default 0)
```

## Privacy

DWIM sends two things to TypeSafe's API: the words you type into the palette, and the titles of the frontmost app's menu items. It never reads or sends document content, window contents or screenshots. Submenus that usually hold personal data (recent files, history, bookmarks, shared albums, window titles) are skipped and never sent; see `privateMenus` in `app/main.swift`. That list is a fixed set of names, so an app with an unusual menu could still expose a personal string. Check the list if that matters to you.

## Limits

- Only what is in the menu bar. Toolbar-only and inspector-only features are out of reach, and apps with thin menus (many Electron apps) have little to find.
- One request, one menu item. Items that open a dialog just open it.
- A rebuild changes the app's signature, so macOS forgets the Accessibility grant. To make it stick, create a self-signed *Code Signing* certificate named `DWIM Dev` in Keychain Access (Certificate Assistant → Create a Certificate); `build.sh` uses it automatically.
- Phrasing matters somewhat. If the first wording misses, the list usually has the right item.

## How it works

`app/main.swift` is the whole app (AppKit, no dependencies): menu reading via `AXUIElement`, the Jev client, the floating panel, and the Option-tap trigger. `app/build.sh` compiles it into `DWIM.app`; `app/rebuild-and-relaunch.sh` also clears the stale Accessibility entry after a rebuild.

You can test ranking from the terminal without the panel: `DWIM.app/Contents/MacOS/DWIM --query Finder "zip these files"` prints the top five menu items for a running app (add `--run` to press the first).

## License

MIT
