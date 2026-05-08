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
- Parallel sync across enabled library profiles and assets (bounded concurrency).
- Keeps local exports when source assets are deleted.
- Sync policy supports **Wi-Fi only** mode (default).
- Default sync interval is **once per day**.
- On app startup, a sync is triggered automatically when the last scheduled run was missed.
- Menu bar shows live sync progression, including currently copied file and recent copied files.
- Menu bar shows an error indicator and recent error log when sync failures occur.
- Optional start-at-login toggle (`SMAppService`).
- About window with app name, version, repository, and author.
- Update checks through GitHub releases (on startup, daily while running, and manually on demand).

## Build

1. Open `ICloudPhotoExporter.xcodeproj` in Xcode.
2. Select the `ICloudPhotoExporter` target.
3. Build and run on macOS 13+.

## CI / Release

- PR validation workflow: `.github/workflows/ci-build.yml`
  - Runs on pull requests to `main`
  - Builds the app in Debug mode on macOS runner to validate compile/build health
- Workflow: `.github/workflows/build-release.yml`
- On `v*` tags (or manual dispatch), it:
  1. Builds the app in Release mode on macOS runner
  2. Signs the app bundle (Developer ID if secrets are configured, ad-hoc fallback otherwise)
  3. Optionally notarizes and staples the app when notarization secrets are configured
  4. Packages binaries as zip files, including a local helper script (`Open-ICloudPhotoExporter.command`) to clear quarantine and open the app on non-notarized local installs
  5. Uploads workflow artifacts with **1 day** retention
  6. Creates/updates a GitHub release and attaches the binaries
- Optional secrets for fully trusted macOS distribution:
  - `MACOS_CERT_P12_BASE64`
  - `MACOS_CERT_P12_PASSWORD`
  - `MACOS_SIGNING_IDENTITY`
  - `APPLE_ID`
  - `APPLE_TEAM_ID`
  - `APPLE_APP_SPECIFIC_PASSWORD`

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
- If Photos permission appears stuck after re-signing or changing signing identity, reset the app's Photos TCC entry and retry:
  `tccutil reset Photos com.meziantou.icloudphotoexporter`
- If the prompt still does not reappear immediately after reset, quit and reopen the app once, then retry sync.
- PhotoKit exports from the current **System Photo Library**. `Shared albums` mode exports assets from iCloud Shared Albums in that system library, either from all shared albums or only selected albums.
- Configured export root folders must already exist; the app does not create missing roots. Date-based subfolders under an existing root are created automatically.
- Export writes are finalized atomically at the destination path (temporary file in destination folder + atomic replace/move), and manifest state is persisted after each successful asset export to reduce crash recovery gaps.
- iCloud-only assets may download during export and can take longer.
- The app stores configuration and manifest under:
  `~/Library/Application Support/ICloudPhotoExporter/`
