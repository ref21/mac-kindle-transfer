# Kindle Drive

Kindle Drive is a small native macOS app for copying files to and from an Amazon Kindle over USB. It uses SwiftUI and libmtp. It needs no Amazon account, no cloud service and no other app such as Calibre.

macOS has no built-in support for MTP, the protocol newer Kindles use over USB, and Amazon's 'Send to Kindle' and 'USB File Manager' apps are no longer (or at least not currently) supported on Apple silicon Macs. This app fills that gap.

## Do you need this?

Amazon says the Kindle Scribe and Kindles released in 2024 or later use MTP and need a separate app on a Mac. Earlier Kindles (except the Scribe) generally appear as a normal USB drive in Finder and do not need this app. Exact model lists are not confirmed, so check how your Kindle shows up when you plug it in.

## Install

### Download (easiest)

You need a Mac with Apple Silicon and macOS 15 or later. To check, open the Apple menu and choose About This Mac. "Chip" should say Apple M1 or later. If it says "Processor" with an Intel name, this app does not run on that Mac.

1. Download **Kindle-Drive-1.3.zip** from the [latest release](https://github.com/ref21/mac-kindle-transfer/releases/latest), under Assets.
2. Open the zip from your Downloads folder. This unpacks **Kindle Drive**.
3. Drag **Kindle Drive** into your Applications folder.
4. Open Kindle Drive. The first time, macOS says it can't verify the app and won't open it, because the app is not notarized by Apple. Click **Done** (not Move to Trash).
5. Open System Settings, then Privacy & Security. Scroll down to the message about Kindle Drive and click **Open Anyway**. Enter your Mac password if asked, then click **Open Anyway** once more.

From then on, Kindle Drive opens normally. Each new version you download needs steps 4 and 5 again.

If you are comfortable with Terminal, this command does the same as steps 4 and 5:

```
xattr -dr com.apple.quarantine "/Applications/Kindle Drive.app"
```

### Build from source

Building the app yourself means macOS trusts it without the steps above. It takes about 10 to 20 minutes the first time, mostly waiting. You type commands into Terminal (in Applications, then Utilities). Paste each command, press Return, and wait for it to finish before the next one.

1. Install Homebrew, a free tool that installs the parts the build needs. Copy the install command from [brew.sh](https://brew.sh) and paste it into Terminal. When it asks for your password, type your Mac password; nothing appears on screen while you type, which is normal. If it offers to install Apple's Command Line Tools, let it.
2. When Homebrew finishes, it prints **Next steps** with two or three commands. Paste and run them. Without them, the `brew` command is not found.
3. Install libusb:

   ```
   brew install libusb
   ```

4. Download this project:

   ```
   git clone https://github.com/ref21/mac-kindle-transfer.git
   ```

5. Go into its folder:

   ```
   cd mac-kindle-transfer
   ```

6. Build the app and copy it into Applications:

   ```
   ./scripts/build.sh --install
   ```

The first build also compiles the bundled libmtp, which takes a few minutes. When it prints `Installed: /Applications/Kindle Drive.app`, open Kindle Drive from Applications. Quit Kindle Drive before building it again.

To build without installing, run `./scripts/build.sh`. The app is then written to `dist/Kindle Drive.app`.

What the build needs: an Apple Silicon Mac (Intel and universal builds are not supported yet), macOS 14 or later (tested on macOS 15 and later), Xcode or the Command Line Tools with Swift 6 or later, and Homebrew's libusb. The built app's minimum macOS version is also limited by the Homebrew libusb it bundles. Homebrew builds libusb for the Mac it is installed on, so an app built on a newer Mac may require that newer macOS. `build.sh` prints a note when this happens.

## Using the app

1. Connect the Kindle with a data-capable USB cable (some cables only charge).
2. Wake the Kindle and make sure it is set to file transfer.
3. Quit other apps that may use the Kindle: Amazon's Send to Kindle (USB File Manager), Calibre, OpenMTP, Android File Transfer. Preview and Image Capture have also been reported to hold MTP devices. Only one app can use the Kindle's MTP connection at a time.
4. Open Kindle Drive. It tries to connect when it starts. If no Kindle is found, it shows a note and no error; click Connect Kindle to try again.

What you can do:

- **Select.** Click an item. Command-click adds or removes items. Shift-click selects a range. Command-A selects all visible items. Double-click a folder to open it. Use the breadcrumb bar or the Parent Folder button to go back up. The sidebar lists the storages and shortcuts to common folders (documents, audible, fonts, screenshots, books, koreader) that exist on your Kindle.
- **Sort.** Click Name, Size or Modified. Click again to reverse.
- **Add files.** Use Add Files (Command-O) or drag files and folders into the list. Drop them onto a folder in the list, a breadcrumb or a sidebar shortcut to copy them into that folder. Folders are copied with their contents.
- **Move.** Drag items onto a folder in the list, a breadcrumb or a sidebar shortcut to move them there. A drag that starts on an item moves it; to select several items by dragging, start in empty space. An item whose name already exists in the destination is skipped and listed in Activity. A book's `.sdr` folder (reading position and notes) moves with it. The Kindle's own top-level folders (documents, fonts, …) cannot be moved. Moving needs a Kindle that supports MTP moves (see Known limitations).
- **Save to Mac.** Select items, then Save to Mac (Shift-Command-S), or use the context menu. Folders are copied with their contents.
- **Rename and new folder.** Rename is in the Kindle menu and the context menu. New Folder is Shift-Command-N.
- **Delete.** Select items, then Delete in the Kindle menu, the context menu, the toolbar or the Delete key. Delete asks for confirmation and is permanent. Folders are deleted with everything in them. After deleting, the app checks a fresh listing from the Kindle. Items that are still there are reported as not deleted. Activity lists the exact path of each item confirmed deleted.
- **Name conflicts.** Copies are never made over an existing file. A copy whose name is taken gets a number, such as `book (2).azw3`, both on the Kindle and on your Mac. Rename refuses a name that already exists.
- **Search.** The search field filters the current folder by name.
- **Hidden files.** Kindle, Show Hidden Files (Shift-Command-period) shows names that start with a dot.
- **Cancel.** Copies, deletes and moves show progress in the status bar and have a Cancel button. Files already copied and items already deleted or moved stay that way. If cancelling or a failed upload may have left an incomplete copy on the Kindle, an alert says which file; delete it before trying again.
- **Activity.** The clock button in the status bar lists what happened in this session, including skipped items.

During an upload these items are skipped and listed in Activity: `.DS_Store`, `.localized` and `._` files, symbolic links, items that are not regular files or folders, items that cannot be read, files of 4 GB or more, and names the Kindle cannot use.

If you add `.epub` files, the app notes that the Kindle's built-in reader generally can't open them. They need converting (for example to AZW3 or KFX with Send to Kindle or Calibre). Reader apps such as KOReader can open them.

Put books in the `documents` folder. Files at the top level of the storage generally do not show up in the library.

If you quit while a copy, delete or move is running, the app asks whether to stop it first. Closing the window does not stop it: the operation keeps running, and clicking the Dock icon brings the window back.

## Troubleshooting

**"No Kindle was detected" or "could not be opened".** Check the cable (it must carry data) and that the Kindle is awake and in file-transfer mode. Quit the other apps listed above. If it still fails, quit and reopen Kindle Drive, or unplug and replug the Kindle.

**The Kindle was unplugged or stopped responding during an operation.** The app checks whether the Kindle is still there. If not, it shows an alert and returns to the disconnected state. Reconnect the cable and click Connect Kindle. Releasing a dead connection can take a while; Connect stays disabled until it finishes. After a connection fails like this, the Kindle may also leave transfer mode; if it does, switch it back or replug the cable.

**Changes made on the Kindle do not show up.** Libmtp caches file details for each session. Disconnect and connect again.

**An incomplete file is left after an interrupted upload.** The app tries to remove it. If it cannot be sure, it says "An incomplete copy of ‘name’ may remain on the Kindle." Delete that file, then upload again.

**Items on the Kindle that "could not be read".** The folder view shows a note when some items in a folder could not be read. Such items are not listed, and a folder that contains one cannot be deleted by the app. Folder downloads skip them without a message.

**Build errors.** The path of the checkout must not contain spaces; libmtp's build does not support that. `build.sh` stops with a message if it does. It also stops if `swift`, Homebrew or libusb is missing.

## Known limitations

- Tested on one Kindle Paperwhite only. The Kindle Scribe, Colorsoft and other models are untested. Libmtp's device table knows only the Scribe by name; other models are detected generically.
- **Cancelling an upload can leave the Kindle refusing new items.** On the tested Paperwhite, after an upload is cancelled partway, the Kindle still lists and deletes, but later copies to it and new folders hang for about a minute and then fail. Unplug and replug the Kindle to recover. The app warns about this when you cancel a copy partway through a file, and explains it again if a later copy or new folder times out. Cancelling a download has not been checked on hardware.
- Not yet tested on hardware: very large transfers, unplugging during a transfer, file names with characters such as `: * ? " < > |`, and models other than the Paperwhite. The same goes for the quit confirmation during a real transfer and sleep prevention during transfers.
- Apple Silicon only. macOS 14 has only been compile-checked.
- The app reaches only the storage the Kindle exposes over USB.
- Deleting is permanent. There is no trash.
- Moving depends on the Kindle supporting MTP's MoveObject; `--probe` prints whether it does. A Kindle Paperwhite supports it. Items cannot be dragged out to Finder; use Save to Mac.
- Moving needs the built app (`dist/Kindle Drive.app`). With `swift run`, dropped Kindle items do nothing.
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
- `--smoke-test` writes to a real Kindle. It creates one uniquely named folder (`KindleDrive-Test-` plus a random ID) at the storage root. In it, it tests upload, duplicate naming, renames, decomposed-name handling, downloads, nested folders, cancelling an upload and verified deletion. Then it deletes the folder, and creates and deletes one more `KindleDrive-Test-AfterCancel-...` folder to check that the Kindle still accepts new items after the cancel. `--smoke-test --documents` first creates test files and a folder in `documents/`, all named `KindleDrive-Test-...`, reports each upload by name, deletes them and checks that they do not reappear. Run these only on a Kindle you are willing to test with.

The app icon `Resources/AppIcon.icns` is generated by this script:

```
swift scripts/make-icon.swift
```

## Testing status

Version 1.3 has been used in the app with one Kindle Paperwhite, including moving items by mouse. Cancel and disconnect handling are also covered by automated tests that run against a fake device. On the Paperwhite, `--probe` passes, and `--smoke-test` passes every step up to its last one: listing, upload, rename, download, moves, cleanup after a cancelled upload, and verified deletion. Its last step then fails because of the cancel problem described under Known limitations. See Known limitations for what is untested.

## Licence and third-party software

The app is released under the licence in `LICENSE`. It bundles libmtp and libusb (LGPL 2.1 or later) as replaceable libraries; see `THIRD_PARTY.md`.

Kindle is a trademark of Amazon. This project is not affiliated with Amazon.
