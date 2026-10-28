# Kindle Drive

A small native macOS USB file manager for Amazon MTP Kindles. SwiftUI interface, libmtp transport, no account, cloud service, Electron, or running Calibre dependency.

## Using the app

Open `Kindle Drive.app`. Connect your Kindle using a data-capable USB cable and enable USB file transfer on the Kindle. Close Send to Kindle, Calibre, and other MTP applications while using Kindle Drive. Click Connect Kindle if needed.

- Click a file or folder to select it. Command-click selects separate items, Shift-click selects a range, and Command-A selects everything visible. Double-click folders to open them; use the breadcrumb or up arrow to navigate.
- Click Name, Size, or Modified to sort; click again to reverse the direction. Size sorts by bytes and Modified by full timestamps.
- Use Add Files or drag files/folders into the file list. Entire folders and multiple files are supported.
- Select files/folders and use Save to Mac to download them, including folder contents.
- Use the context menu or Kindle menu to rename; use New Folder to create folders.
- Delete requires confirmation and is permanent, including all contents of selected folders. Each deleted item is checked against a fresh device listing; items that remain or reappear are reported as unconfirmed rather than successful. Successful batches record exact paths in Activity.
- Name conflicts preserve both copies with a numbered suffix. Existing files are never deliberately replaced.
- Search filters the current folder. Command-Shift-period toggles hidden files.
- Transfers show current-file progress and support cancellation. Already completed files remain; cancellation during folder operations can leave a partially copied folder.
- The activity button shows results from this app session.

The app keeps one MTP session open while in use. Disconnect closes that session and may make the Kindle leave USB transfer mode; re-enable transfer mode or reconnect the cable before connecting again. Unexpected cable removal may require Disconnect then Connect, or restarting the app. Only the Kindle's exposed USB storage is accessible.

## Build

Requirements: Apple Silicon Mac, macOS 15+, Xcode/Swift 6+, and Homebrew libusb 1.0.29 (`brew install libusb`).

Run `./scripts/build.sh`. The self-contained, ad-hoc signed application is written to `dist/Kindle Drive.app`; it bundles replaceable libmtp/libusb libraries and does not need Homebrew on the destination Mac. The build currently targets the build machine's architecture. Distribution to other users would benefit from Developer ID signing and notarization.

libmtp 1.1.22 source is in Vendor/libmtp-1.1.22. The build uses a local shared library produced from its C objects with the unmodified public API. To rebuild dependencies, remove Vendor/installed/lib/libmtp.9.dylib and run the build script. See THIRD_PARTY.md for licenses and source links.

Run unit tests with:

```
CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache" swift test --disable-sandbox --cache-path .cache
```

The executable accepts `--probe` for read-only root browsing and `--smoke-test` for a device test. The latter creates a unique temporary folder, verifies upload, collision naming, rename, exact download contents, nested folder copies, and recursive deletion, and cleans up its test folder. It never intentionally modifies existing user content. Closing either test session may exit the Kindle's USB transfer mode.

## Validation on the connected Paperwhite

Passed live folder listing, new folder creation, upload, duplicate-name preservation, file rename, byte-for-byte download verification, nested upload/download, recursive deletion, and cleanup. Path-validation, filename-collision, bidirectional sorting, and deletion-verification unit tests also passed. Version 1.1 was checked in the installed UI for single-click, Command-click, Shift-click folder selection and all three sortable columns. Temporary text, crash-log-style, zero-byte, and nested-folder fixtures in documents were deleted and confirmed absent across fresh listings and a new USB session. The user-reported return of original KPPMainAppV2 logs was not reproduced; those original files were left intact. Very large transfers, physical disconnection during a transfer, and cancellation recovery have not yet been tested on hardware.
