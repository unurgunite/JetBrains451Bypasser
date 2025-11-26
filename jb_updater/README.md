# jb_updater

A standalone **Crystal CLI + GUI** to list, update, install and even **upgrade JetBrains IDEs** — without launching the
IDE.

It is designed to work even when JetBrains Marketplace / download servers return HTTP **451** (unavailable for legal
reasons) by switching to CDN mirrors and direct API calls.

---

* [jb_updater](#jb_updater)
    * [Features](#features)
    * [Binaries](#binaries)
    * [CLI Usage](#cli-usage)
        * [Plugins mode](#plugins-mode)
        * [IDE upgrade mode](#ide-upgrade-mode)
        * [Homebrew Cask patch mode (macOS, WIP)](#homebrew-cask-patch-mode-macos-wip)
    * [CLI Options (subset)](#cli-options-subset)
    * [GUI Usage](#gui-usage)
    * [Run from source](#run-from-source)
    * [Development](#development)
    * [CI/CD](#cicd)
    * [Notes](#notes)
    * [License](#license)

## Features

- Lists installed plugins and marks their compatibility.
- Updates only incompatible or selected plugins.
- Installs new plugins by `xmlId`, pinned version, or direct CDN URL.
- Bypasses 451 HTTP errors by rewriting hosts to JetBrains CDN / mirrors.
- Upgrades entire IDEs via the JetBrains Releases API.
- Auto‑detects architecture (`arm` or `intel`) and fetches the correct build.
- Compact progress bar while downloading (CLI) and progress bars in GUI.
- Zero runtime dependencies: self‑contained native binaries.
- Optional `--brew` mode patches a Homebrew Cask so `brew upgrade` just works (macOS).

---

## Binaries

Prebuilt binaries are attached to [GitHub Releases](../releases):

Per OS you’ll find:

- **CLI only** archives:
    - `jb_updater-linux-x86_64.tar.gz`
    - `jb_updater-macos-${arch}.tar.gz`
    - `jb_updater-windows-x64.zip`
- **GUI only** archives:
    - `jb_updater-gui-linux-x86_64.tar.gz`
    - `jb_updater-gui-macos-${arch}.zip` (contains a `JBUpdater.app`)
    - `jb_updater-gui-windows-x64.zip`
- **Bundles** (CLI + GUI together):
    - `jb_updater-bundle-linux-x86_64.tar.gz`
    - `jb_updater-macos-${arch}-binaries.zip`
    - `jb_updater-bundle-windows-x64.zip`

On macOS, `JBUpdater.app` bundles both `jb_updater_gui` and `jb_updater` in `Contents/MacOS`.

> [!NOTE]
> macOS builds are unsigned / unnotarized. You may need to clear quarantine locally:
> ```bash
> xattr -cr JBUpdater.app
> open JBUpdater.app
> ```

---

## CLI Usage

Show help:

```bash
jb_updater --help
```

### Plugins mode

Update plugins for a specific IDE:

```bash
jb_updater \
  --plugins-dir "$HOME/Library/Application Support/JetBrains/RubyMine2025.2/plugins" \
  --only-incompatible
```

Install specific plugins by ID:

```bash
jb_updater \
  --plugins-dir "$HOME/Library/Application Support/JetBrains/WebStorm2025.2/plugins" \
  --install-plugin org.jetbrains.plugins.vue,com.intellij.database
```

### IDE upgrade mode

Upgrade an IDE by product name:

```bash
# auto‑detect architecture and download from JetBrains CDN
jb_updater --product RubyMine --upgrade-ide
```

Upgrade by explicit path:

```bash
jb_updater --ide-path /Applications/WebStorm.app --upgrade-ide
```

### Homebrew Cask patch mode (macOS, WIP)

> [!WARNING]
> `--brew` is still experimental, not recommended to use.

Instead of downloading the DMG directly, patch a Homebrew Cask:

```bash
jb_updater --product WebStorm --upgrade-ide --brew
# then run:
#   brew upgrade webstorm
```

---

## CLI Options (subset)

| Option                       | Description                                                   |
|------------------------------|---------------------------------------------------------------|
| `--plugins-dir DIR`          | Plugins directory                                             |
| `-b`, `--build BUILD`        | IDE build                                                     |
| `-d`, `--dry-run`            | Dry run                                                       |
| `-l`, `--list`               | List plugins                                                  |
| `-i`, `--install-plugin IDS` | Install plugins (comma-separated)                             |
| `--product NAME`             | IDE product name (e.g., RubyMine or RubyMine2025.2)           |
| `--arch ARCH`                | Architecture (`arm` or `intel`); default: autodetect          |
| `--upgrade-ide`              | Upgrade whole IDE instead of plugins                          |
| `--ide-path PATH`            | Specify custom IDE installation path                          |
| `--list-ide-releases`        | List available IDE releases by product code (e.g. `RM`, `WS`) |
| `--no-tty-progress-bar`      | Disable ASCII TTY progress bars (useful with GUI wrapper)     |
| `--brew`                     | Patch Homebrew cask Ruby file (macOS, WIP)                    |
| `-h`, `--help`               | Show help                                                     |

---

## GUI Usage

The GUI is built with [uing](https://github.com/kojix2/uing) and provides:

- Tabs for **Plugins** and **IDE upgrade**.
- Auto‑detection of installed IDEs on macOS (and partially on other OSes via config dirs).
- Shared log, overall progress bar, and per‑plugin progress bar.
- Buttons for:
    - List installed plugins,
    - Install by plugin IDs,
    - Update all plugins,
    - List IDE releases,
    - Upgrade IDE,
    - Detect plugins dir from product name,
    - Clear console,
    - Remove `*.bak*` plugin backups.

On macOS:

1. Download `jb_updater-gui-macos-${arch}.zip` from Releases.
2. Unzip and move `JBUpdater.app` to `/Applications`.
3. (First run) Clear quarantine:

   ```bash
   xattr -cr /Applications/JBUpdater.app
   open /Applications/JBUpdater.app
   ```

On Linux/Windows:

- Use the `*-bundle-*` archives so GUI and CLI are in the same directory.
- Run the GUI binary (`./jb_updater_gui` or `jb_updater_gui.exe`).

---

## Run from source

```bash
git clone https://github.com/unurgunite/JetBrains451Bypasser.git
cd JetBrains451Bypasser/jb_updater
shards install

# CLI
crystal build src/main.cr --release -o jb_updater
./jb_updater --help

# GUI
crystal build src/gui/main_gui.cr --release -o jb_updater_gui
./jb_updater_gui
```

---

## Development

Run unit tests:

```bash
crystal spec
```

Lint with [Ameba](https://github.com/crystal-ameba/ameba):

```bash
./bin/lint
```

Build optimized binaries:

```bash
crystal build src/main.cr --release -o jb_updater
crystal build src/gui/main_gui.cr --release -o jb_updater_gui
```

---

## CI/CD

Cross‑platform binaries are built automatically via **GitHub Actions** on:

- pushes to `master` / tags `v*.*.*`,
- and manual triggers (`workflow_dispatch`).

Workflows:

- `.github/workflows/build-release.yml`
    - runs specs,
    - runs Ameba,
    - builds CLI + GUI,
    - packages and uploads artifacts for Linux/macOS/Windows.
- `.github/workflows/test-build.yml`
    - runs a fast build + smoke test on PRs.

To create a tagged release:

```bash
git tag -a v0.2.0 -m "Cross‑platform build"
git push origin v0.2.0
```

GitHub Actions will attach fresh binaries for that tag to the Release page.

---

## Notes

- Close your JetBrains IDE before updating plugins (to avoid locked files).
- Requires the system `unzip` tool for extracting plugin archives.
- Tested on:
    - macOS (ARM + Intel),
    - Linux (x86_64, GTK3 for GUI),
    - Windows (x64, MSVC toolchain via CI).

---

## License

MIT © 2025 Unurgunite
