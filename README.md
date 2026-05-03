# iCloud Photo Exporter (macOS)

Menu bar macOS app (Swift + Xcode) that exports Apple Photos/iCloud assets to local folders with incremental sync.

## Features

- Runs as a background menu bar app (`LSUIElement`).
- Uses PhotoKit to fetch and export Apple Photos assets.
- Supports multiple library profiles with per-profile output settings.
- Per-profile source selection:
  - Main library
  - Shared albums (all or selected albums)
- Per-library initial sync baseline:
  - Full history
  - From date
  - From latest photo (recommended for new users)
- Live Photo export includes both still image and paired video resources (for example `HEIC + MOV`).
- Year/Month output folder layout.
- Incremental sync via persisted manifest.
- Keeps local exports when source assets are deleted.
- Sync policy supports **Wi-Fi only** mode (default).
- Default sync interval is **once per day**.
- On app startup, a sync is triggered automatically when the last scheduled run was missed.
- Menu bar shows an error indicator and recent error log when sync failures occur.
- Optional start-at-login toggle (`SMAppService`).

## Build

1. Open `ICloudPhotoExporter.xcodeproj` in Xcode.
2. Select the `ICloudPhotoExporter` target.
3. Build and run on macOS 13+.

## CI / Release

- Workflow: `.github/workflows/build-release.yml`
- On `v*` tags (or manual dispatch), it:
  1. Builds the app in Release mode on macOS runner
  2. Packages binaries as zip files
  3. Uploads workflow artifacts with **1 day** retention
  4. Creates/updates a GitHub release and attaches the binaries

## First run

1. Open **Settings** from the menu bar item.
2. Add one or more library profiles.
3. Pick the output folder for each profile.
4. Choose source (main library / shared albums), optionally pick specific shared albums, and set initial sync mode (full / from date / latest).
5. (Optional) Enable **Start at login**.
6. Keep **Sync on Wi-Fi only** enabled (default) unless you want syncing on any network.
7. Click **Sync now**.

## Notes

- PhotoKit access requires Photos permission at runtime.
- PhotoKit exports from the current **System Photo Library**. `Shared albums` mode exports assets from iCloud Shared Albums in that system library, either from all shared albums or only selected albums.
- Configured export root folders must already exist; the app does not create missing roots. Date-based subfolders under an existing root are created automatically.
- iCloud-only assets may download during export and can take longer.
- The app stores configuration and manifest under:
  `~/Library/Application Support/ICloudPhotoExporter/`
