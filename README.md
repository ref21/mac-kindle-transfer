# Kindle Drive

Kindle Drive is a small native macOS app for copying files to and from an Amazon Kindle over USB. It uses SwiftUI and libmtp. It needs no Amazon account, no cloud service and no other app such as Calibre.

macOS has no built-in support for MTP, the protocol newer Kindles use over USB. This app fills that gap.

## Do you need this?

Amazon says the Kindle Scribe and Kindles released in 2024 or later use MTP and need a separate app on a Mac. Earlier Kindles (except the Scribe) generally appear as a normal USB drive in Finder and do not need this app. Exact model lists are not confirmed, so check how your Kindle shows up when you plug it in.

Windows and Linux already show MTP Kindles in their file managers, so there is no plan for a port.

## Install

Building from source is the recommended route. You need:

- A Mac with Apple Silicon. Intel and universal builds are not supported yet.
- macOS: built for macOS 14 or later; tested on macOS 15 and later.
- Xcode or the Command Line Tools, with Swift 6 or later.
- [Homebrew](https://brew.sh) and its libusb package.

```
brew install libusb
```

```
git clone https://github.com/ref21/Kindle_Driver.git
```

```
cd Kindle_Driver
```

```
./scripts/build.sh
```

The first build also compiles the bundled libmtp, which takes a few minutes. The app is written to `dist/Kindle Drive.app`. Drag it to `/Applications` or open it from there.

`./scripts/build.sh --install` builds and then copies the app into `/Applications`, replacing any older copy. Quit Kindle Drive first.

The built app's minimum macOS version is also limited by the Homebrew libusb it bundles. Homebrew builds libusb for the Mac it is installed on, so an app built on a newer Mac may require that newer macOS. `build.sh` prints a note when this happens.

### Prebuilt copies and Gatekeeper

An app you build yourself runs without warnings. A downloaded copy of this app is only ad-hoc signed, not notarized, so macOS blocks it. On macOS 15 and later, Control-click then Open no longer works. Allow the app in System Settings, Privacy & Security, using "Open Anyway". Or remove the quarantine flag:

```
xattr -dr com.apple.quarantine "/Applications/Kindle Drive.app"
```

Newer macOS versions may be stricter still.

## Using the app

1. Connect the Kindle with a data-capable USB cable (some cables only charge).
2. Wake the Kindle and make sure it is set to file transfer.
3. Quit other apps that may use the Kindle: Amazon's Send to Kindle (USB File Manager), Calibre, OpenMTP, Android File Transfer. Preview and Image Capture have also been reported to hold MTP devices. Only one app can use the Kindle's MTP connection at a time.
4. Open Kindle Drive. It tries to connect when it starts. If no Kindle is found, it shows a note and no error; click Connect Kindle to try again.

What you can do:

- **Select.** Click an item. Command-click adds or removes items. Shift-click selects a range. Command-A selects all visible items. Double-click a folder to open it. Use the breadcrumb bar or the Parent Folder button to go back up. The sidebar lists the storages and shortcuts to common folders (documents, audible, fonts, screenshots, books, koreader) that exist on your Kindle.
- **Sort.** Click Name, Size or Modified. Click again to reverse.
- **Add files.** Use Add Files (Command-O) or drag files and folders into the list. Folders are copied with their contents.
- **Save to Mac.** Select items, then Save to Mac (Shift-Command-S), or use the context menu. Folders are copied with their contents.
- **Rename and new folder.** Rename is in the Kindle menu and the context menu. New Folder is Shift-Command-N.
- **Delete.** Select items, then Delete in the Kindle menu, the context menu, the toolbar or the Delete key. Delete asks for confirmation and is permanent. Folders are deleted with everything in them. After deleting, the app checks a fresh listing from the Kindle. Items that are still there are reported as not deleted. Activity lists the exact path of each item confirmed deleted.
- **Name conflicts.** Copies are never made over an existing file. A copy whose name is taken gets a number, such as `book (2).azw3`, both on the Kindle and on your Mac. Rename refuses a name that already exists.
- **Search.** The search field filters the current folder by name.
- **Hidden files.** Kindle, Show Hidden Files (Shift-Command-period) shows names that start with a dot.
- **Cancel.** Copies and deletes show progress in the status bar and have a Cancel button. Files already copied or items already deleted stay that way. If cancelling or a failed upload may have left an incomplete copy on the Kindle, an alert says which file; delete it before trying again.
- **Activity.** The clock button in the status bar lists what happened in this session, including skipped items.

During an upload these items are skipped and listed in Activity: `.DS_Store`, `.localized` and `._` files, symbolic links, items that are not regular files or folders, items that cannot be read, files of 4 GB or more, and names the Kindle cannot use.

If you add `.epub` files, the app notes that the Kindle's built-in reader generally can't open them. They need converting (for example to AZW3 or KFX with Send to Kindle or Calibre). Reader apps such as KOReader can open them.

Put books in the `documents` folder. Files at the top level of the storage generally do not show up in the library.

If you quit while a copy or delete is running, the app asks whether to stop it first. Closing the window does not stop it: the operation keeps running, and clicking the Dock icon brings the window back.

## Troubleshooting

**"No Kindle was detected" or "could not be opened".** Check the cable (it must carry data) and that the Kindle is awake and in file-transfer mode. Quit the other apps listed above. If it still fails, quit and reopen Kindle Drive, or unplug and replug the Kindle.

**The Kindle was unplugged or stopped responding during an operation.** The app checks whether the Kindle is still there. If not, it shows an alert and returns to the disconnected state. Reconnect the cable and click Connect Kindle. Releasing a dead connection can take a while; Connect stays disabled until it finishes. Disconnecting may also make the Kindle leave transfer mode; if it does, switch it back or replug the cable.

**Changes made on the Kindle do not show up.** Libmtp caches file details for each session. Disconnect and connect again.

**An incomplete file is left after an interrupted upload.** The app tries to remove it. If it cannot be sure, it says "An incomplete copy of ‘name’ may remain on the Kindle." Delete that file, then upload again.

**Items on the Kindle that "could not be read".** The folder view shows a note when some items in a folder could not be read. Such items are not listed, and a folder that contains one cannot be deleted by the app. Folder downloads skip them without a message.

**Build errors.** The path of the checkout must not contain spaces; libmtp's build does not support that. `build.sh` stops with a message if it does. It also stops if `swift`, Homebrew or libusb is missing.

## Known limitations

- Tested on one Kindle Paperwhite only. The Kindle Scribe, Colorsoft and other models are untested. Libmtp's device table knows only the Scribe by name; other models are detected generically.
- Not yet tested on hardware: very large transfers, unplugging during a transfer, recovery after cancelling, file names with characters such as `: * ? " < > |`, renaming folders, and models other than the Paperwhite. The same goes for the quit confirmation during a real transfer and sleep prevention during transfers.
- Apple Silicon only. macOS 14 has only been compile-checked.
- The app reaches only the storage the Kindle exposes over USB.
- Deleting is permanent. There is no trash.
- Closing the window during a transfer keeps the app running until it ends; clicking the Dock icon reopens the window.

## Development

Layout:

- `Sources/KindleDrive/` is the app: SwiftUI views (`App.swift`), the browser model (`Model.swift`), device operations (`Device.swift`), the libmtp transport (`Transport.swift`), an in-memory fake device (`FakeTransport.swift`) and the hardware checks (`SmokeTest.swift`).
- `Sources/CMTP/` is a small C shim around libmtp.
- `Vendor/libmtp-1.1.22/` is the libmtp source. `Vendor/installed/` is its build output and is not committed.
- `Tests/` holds the unit tests. `scripts/` holds the build, test and icon scripts.
- `.github/workflows/ci.yml` runs the tests and the build on GitHub.

Run the unit tests. They run against the in-memory device, not a real Kindle:

```
./scripts/test.sh
```

Build options:

- `./scripts/build.sh --deps-only` builds only libmtp.
- `./scripts/build.sh --rebuild-deps` discards the libmtp build and builds it again.
- `./scripts/build.sh --help` prints usage.

To rebuild libmtp from scratch (for example after changing its build settings), use `--rebuild-deps`. Deleting `Vendor/installed` alone is not enough, because old object files in the libmtp tree would be reused.

Command-line flags of the built executable, `dist/Kindle Drive.app/Contents/MacOS/KindleDrive`:

- `--demo` runs the app against an in-memory fake Kindle with sample files. It never touches USB. Use it to look at the interface. It cannot be combined with `--probe` or `--smoke-test`.
- `--probe` is read-only. It connects to a real Kindle and prints the model, USB ID, storages, and the root and `documents` listings. Add `--dump` to also print libmtp's device report. Please attach that output to bug reports about unsupported models.
- `--smoke-test` writes to a real Kindle. It creates one uniquely named folder (`KindleDrive-Test-` plus a random ID) at the storage root. In it, it tests upload, duplicate naming, renames, decomposed-name handling, downloads, nested folders, cancelling an upload and verified deletion. Then it deletes the folder. `--smoke-test --documents` additionally creates test files and a folder in `documents/`, all named `KindleDrive-Test-...`, deletes them and checks that they do not reappear. Run these only on a Kindle you are willing to test with.

The app icon `Resources/AppIcon.icns` is generated by this script:

```
swift scripts/make-icon.swift
```

## Testing status

The app was exercised on one Kindle Paperwhite before release: listing, new folders, upload, duplicate names, rename, download, nested folders and deletion. Later changes to the device layer and the interface (including cancel and disconnect handling) have been checked by automated tests that run against a fake device, and by launching the app in demo mode. Those changes have not all been run on a real Kindle. See Known limitations for what is untested.

## Licence and third-party software

The app is released under the licence in `LICENSE`. It bundles libmtp and libusb (LGPL 2.1 or later) as replaceable libraries; see `THIRD_PARTY.md`.

Kindle is a trademark of Amazon. This project is not affiliated with Amazon.
