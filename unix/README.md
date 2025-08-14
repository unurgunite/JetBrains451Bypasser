# JBUpdater (macOS)

A tiny Ruby CLI to list and update JetBrains IDE plugins on macOS without going through the IDE. It scans your plugins
directory, detects your IDE build, resolves the latest compatible plugin versions via the Marketplace, downloads them (
optionally via the downloads CDN), and installs them safely with backups.

- macOS only (by design in this version)
- No extra gems required
- Uses system `unzip`


* [JBUpdater](#jbupdater-macos)
    * [Why](#why)
    * [Requirements](#requirements)
    * [Installation](#installation)
    * [Typical paths (macOS)](#typical-paths-macos)
    * [Usage](#usage)
    * [Examples](#examples)
    * [How it works](#how-it-works)
    * [Notes](#notes)
    * [Troubleshooting](#troubleshooting)
    * [TODO](#todo)

## Why

If your IDE can't reach the JetBrains Marketplace, this tool lets you:

- list installed plugins and see compatibility for your current IDE build;
- update only incompatible plugins;
- pin specific versions, or provide direct file URLs.

## Requirements

- macOS
- Ruby 3.0+
- `unzip` available on PATH (macOS has it by default)

## Installation

- Save the script (e.g., `jb_updater.rb`)
- Make it executable (optional):  
  `chmod +x jb_updater.rb`

## Typical paths (macOS)

- Plugins dir:  
  `~/Library/Application Support/JetBrains/<ProductYYYY.X>/plugins`  
  e.g., `~/Library/Application Support/JetBrains/RubyMine2025.2/plugins`
- App bundle (default):  
  `/Applications/<IDE Name>.app`  
  e.g., `/Applications/RubyMine.app`

## Usage

The tool’s behavior is controlled by flags; there are no subcommands.

```bash
./jb_updater --plugins-dir "<path>" [options]
```

Options:

```
--plugins-dir DIR Path to …/JetBrains/<ProductYYYY.X>/plugins (required)
--build BUILD IDE build (e.g., RM-252.23892.415). Auto-detected if omitted
--bin-path PATH Explicit path to IDE binary (fallback for detection)
--only IDS Comma-separated plugin xmlIds to update (default: all installed)
--only-incompatible Update only plugins that are currently incompatible
--downloads-host HOST Rewrite final /files/ host (e.g., downloads.marketplace.jetbrains.com)
--pin xmlId=version Pin a plugin to a specific version (can repeat)
--direct xmlId=https://... Use a direct file URL for a plugin (can repeat)
--dry-run Show actions without downloading/installing
--list List installed plugins and compatibility; then exit
-h, --help Show help
```

## Examples

List installed plugins (with compatibility):

```bash

./jb_updater \
--plugins-dir "$HOME/Library/Application Support/JetBrains/RubyMine2025.2/plugins" \
--list
```

Update everything (auto-detect build from /Applications):

```bash
./jb_updater \
--plugins-dir "$HOME/Library/Application Support/JetBrains/RubyMine2025.2/plugins"
```

Update only incompatible plugins, downloading from the CDN host:

```bash
./jb_updater \
--plugins-dir "$HOME/Library/Application Support/JetBrains/RubyMine2025.2/plugins" \
--only-incompatible \
--downloads-host downloads.marketplace.jetbrains.com
```

Pin a specific version of a plugin:

```bash
./jb_updater \
--plugins-dir "$HOME/Library/Application Support/JetBrains/RubyMine2025.2/plugins" \
--pin org.jetbrains.plugins.yaml=2024.1.3
```

Provide a direct /files URL you already have:

```bash
./jb_updater \
--plugins-dir "$HOME/Library/Application Support/JetBrains/RubyMine2025.2/plugins" \
--direct org.jetbrains.plugins.yaml=https://downloads.marketplace.jetbrains.com/files/123456/yaml-2024.1.3.zip
```

Specify build or binary manually (if auto-detection can’t find the app):

```bash
./jb_updater \
--plugins-dir "$HOME/Library/Application Support/JetBrains/RubyMine2025.2/plugins" \
--build RM-252.23892.415

./jb_updater \
--plugins-dir "$HOME/Library/Application Support/JetBrains/RubyMine2025.2/plugins" \
--bin-path /Applications/RubyMine.app/Contents/MacOS/rubymine
```

## How it works

- Detects the IDE and build:
  Infers product from the plugins directory (e.g., RubyMine2025.2 → RubyMine).
  Reads `product-info.json` or `build.txt` from `/Applications/<App>.app` to get `<productCode>-<buildNumber>`.
  Optionally uses `--bin-path` to run <binary> `--version` as a fallback.
- Scans installed plugins:
  Reads META-INF/plugin.xml (unpacked or inside `lib/*.jar`) to get xmlId, version, and since/until build.
- Resolves downloads:
  Latest compatible: `https://plugins.jetbrains.com/pluginManager?action=download&id=<xmlId>&build=<code>-<build>`
  Specific version: `https://plugins.jetbrains.com/plugin/download?pluginId=<xmlId>&version=<version>`
  Follows the redirect to the final /files/... URL; can rewrite the host to downloads.marketplace.jetbrains.com.
- Installs safely:
  Downloads to a temp file.
  Extracts to a temp dir, backs up the existing plugin folder as `.bak.<timestamp>`, and replaces it.

## Notes

- Close the IDE before running to avoid file-lock or partial state.
- This script updates user plugins in the config directory, not bundled platform plugins. (will be fixed in the future)

## Troubleshooting

- "Could not detect IDE build": pass --build RM-... or --bin-path /Applications/<App>.app/Contents/MacOS/<bin>.
  HTTP 451 from plugins.jetbrains.com: try --downloads-host downloads.marketplace.jetbrains.com (works for the final
  /files/ host).
- "unzip not found": ensure unzip is available on PATH (macOS usually has it).
- Plugin remains incompatible after update: the Marketplace may not have a version compatible with your IDE build yet.

## TODO

- Add support for Windows.
- Add support for Linux.
- Add support for bundled plugins.
- Move to RubyGems.org.
