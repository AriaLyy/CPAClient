# CPAClient

[简体中文](README.zh-CN.md)

CPAClient is a Flutter desktop client that manages and runs [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) locally.
It provides a settings-first experience for downloading/updating the core binary, managing WebUI access, and synchronizing `config.yaml` via WebDAV.

## Features

- **One-click core bootstrap**
  - Initializes sandbox directories and `config.yaml`
  - Downloads the correct CLIProxyAPI release asset by OS/arch
  - Starts the core process automatically
- **Core management UI**
  - Select recent core versions from GitHub releases
  - Update/restart core
  - Open WebUI directly (`http://127.0.0.1:<port>/management.html#/login`)
  - Quick-open `config.yaml`, config directory, and sandbox directory
- **Security & access settings**
  - Save GitHub token (for release API access / rate-limit avoidance)
  - Save WebUI password (`remote-management.secret-key`)
- **WebDAV sync**
  - Save WebDAV endpoint/credentials
  - Test connection
  - Backup and restore `config.yaml`
  - Visual sync status (idle/running/success/failure)
- **Desktop integration**
  - Tray menu: WebUI / Settings / Exit
  - Launch at startup toggle
  - Light / Dark / System theme

## Tech Stack

- Flutter (Material 3)
- Desktop plugins: `tray_manager`, `window_manager`, `launch_at_startup`, `url_launcher`
- Networking/files: `http`, `dio`, `archive`, `yaml`, `path_provider`

## Supported Platforms

Runtime support follows Flutter desktop targets and the bundled core binary format.
Current release workflow builds:

- Linux: `amd64`, `arm64`
- macOS: `amd64`, `arm64`
- Windows: `amd64`, `arm64`

## Project Structure

```text
lib/
  app/                      # App root (theme + MaterialApp)
  core/
    constants/              # Default constants
    models/                 # App settings / GitHub release models
    services/               # Startup, downloader, process manager, config/path/log services
  features/
    settings/               # Settings page + controller (main UI)
    tray/                   # System tray integration
configs/
  config.yaml               # Bundled default config template
.github/workflows/
  release.yml               # Multi-platform desktop release pipeline
```

## Quick Start (Development)

### 1) Prerequisites

- Flutter SDK (project currently uses stable `3.35.5` in CI)
- Dart SDK compatible with `sdk: ^3.6.2`
- Platform-specific desktop toolchain:
  - **Windows**: Visual Studio C++ desktop workload
  - **macOS**: Xcode command line tools
  - **Linux**: `clang`, `cmake`, `ninja-build`, `pkg-config`, `libgtk-3-dev`, and appindicator dev package

### 2) Install dependencies

```bash
flutter pub get
```

### 3) Run desktop app

```bash
flutter run -d windows
# or
flutter run -d macos
# or
flutter run -d linux
```

## First Launch Flow

1. App creates sandbox data automatically.
2. If core binary is missing, app requires a GitHub token and downloads core release asset.
3. App starts core process with local `config.yaml`.
4. You can open WebUI from Settings or Tray.

## Data & Config Storage

CPAClient stores runtime data under the app support directory (via `path_provider`), including:

- `sandbox/bin/` (core binary)
- `sandbox/config/config.yaml`
- `sandbox/app_settings.json`
- `sandbox/app.log`

Use the Settings shortcuts to open these paths directly.

## Build & Release

Tag-based release pipeline is defined in `.github/workflows/release.yml`:

- Trigger: push tag matching `v*`
- Matrix build across Linux/macOS/Windows and amd64/arm64 variants
- Packages artifacts (`.tar.gz` for Linux/macOS, `.zip` for Windows)
- Uploads assets to GitHub Release for the tag

## Local Packaging

Use the Python script to package on the current host OS:

```bash
python3 tool/package_local.py
```

Optional arguments:

- build version: `--build-name`, `--build-number`
- package only: `--skip-build`
- output folder: `--output-dir`

macOS local signing:

- sign app bundle: `--macos-sign-identity "Developer ID Application: ..."`
- ad-hoc signing: `--macos-sign-identity "-"`
- optional entitlements: `--macos-entitlements path/to/entitlements.plist`

Output artifacts are written to `release/` by default and follow CI naming:

- Linux: `linux_<arch>.tar.gz`
- macOS: `darwin_<arch>.tar.gz`
- Windows: `windows_<arch>.zip`

Note: local packaging is host-native (Windows builds Windows, macOS builds macOS, Linux builds Linux).

## Security Notes

- Keep your GitHub token and WebDAV credentials private.
- `config.yaml` may contain sensitive keys; avoid exposing or committing local runtime copies.
- Prefer localhost-only management unless you understand remote exposure risks.

## Troubleshooting

- **403 when fetching releases**: configure GitHub token in Settings.
- **Core update failed**: check app log path shown in UI message.
- **WebDAV backup/restore failed**: verify URL/credentials and test connection first.

## Related Projects

- CLIProxyAPI: https://github.com/router-for-me/CLIProxyAPI
- CPAClient: https://github.com/AriaLyy/CPAClient
