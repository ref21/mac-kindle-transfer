# Changelog

## 1.3 — unreleased

### Added
- Move items between folders: drag them onto a folder in the list, a breadcrumb or a sidebar shortcut. Uses the Kindle's MTP move; items whose name is taken in the destination are skipped and listed in Activity. A book's `.sdr` folder (reading position and notes) moves with it, and the Kindle's own top-level folders (documents, fonts, …) cannot be moved. Moves are checked against a fresh listing and can be cancelled between items.
- Finder files dropped onto a folder in the list, a breadcrumb or a sidebar shortcut are copied into that folder.
- `--probe` prints whether the Kindle supports moving; `--smoke-test` moves a file and a folder with contents into a folder and back, and a file to the top level and back.

### Fixed
- Kindle Drive no longer crashes while connecting if the Kindle refuses the first connection; this was seen after a smoke test that had left the Kindle stuck. libmtp then resets the Kindle's USB, the Kindle treats the reset as an eject and drops off USB, and libmtp went on using the lost connection. After about 15 seconds the app now shows "could not be opened" with advice to unplug and replug the Kindle and reopen the app.

### Not validated on hardware
Dragging and dropping was tried by hand in demo mode, and the smoke test's moves pass on a Kindle Paperwhite. Moving by mouse in the app has not yet been tried on a Kindle. The connect-crash fix was traced through the libusb source and crash report but not yet reproduced on a Kindle.

## 1.2 — unreleased

### Fixed
- The Kindle no longer drops off USB when Kindle Drive disconnects or quits. libmtp sent the Kindle a USB reset on every disconnect, which the Kindle treated as an eject.
- After a copy is cancelled partway through a file, the Kindle may stop accepting new files until it is unplugged and plugged back in. The app now says so at the cancel, and if a later copy or new folder times out it explains how to recover instead of showing only a PTP error.
- A failed or cancelled upload no longer risks deleting the wrong item. Only the partial file the upload itself created is removed, and if that cannot be confirmed, the app tells you an incomplete copy may remain.
- Delete now checks a fresh listing from the Kindle. Items that are still there are reported instead of counted as deleted, and confirmed paths are logged in Activity.
- Folders that contain items the app could not read are no longer deleted, and unreadable items are reported in the folder view.
- A cancel no longer shows an error. It shows an alert only when something needs your attention, such as an incomplete copy that may remain.
- An unplugged Kindle is detected and the app returns to the disconnected state with one message.
- A failed folder change no longer leaves the file list out of step with the current folder.
- Launching the app without a Kindle connected shows a short note instead of an error alert.
- Window tabbing is turned off, and quitting during a transfer asks first.
- Names with accents are stored in a form the Kindle lists back unchanged, and file names with characters Mac cannot use are made safe when saving.
- The sidebar shortcuts come from folders that exist on the Kindle instead of a fixed list.
- Command-A in the search field selects text, and Command-Delete no longer deletes items.

### Changed
- Progress shows the current item (for example "3 of 20") and no longer redraws the whole window.
- Upload and delete checks were reduced to fewer round trips to the Kindle.
- Build: portable link flags, no build-machine paths in the app, preflight checks with clear messages, and a minimum macOS check. The build targets macOS 14 or later; it has been tested on macOS 15 and later.
- Single-item counts read "1 item".

### Added
- `--demo` runs the app against a fake Kindle, with no USB.
- Skipped items are listed in Activity, with a note when `.epub` files are copied.
- `scripts/test.sh`, unit tests against a fake device, and a GitHub Actions workflow.
- The Kindle's USB ID is logged in Activity on connect; `--probe` prints more detail and `--dump` adds libmtp's device report.
- Sleep is prevented while a transfer runs.
- `--smoke-test` checks that the Kindle still accepts new items after a cancelled upload; `--documents` runs first and reports each upload by name.
- README, CHANGELOG and a `LICENSE` file.

### Not validated on hardware
These changes were checked only against a fake device or by reading code, not on a real Kindle: handling of an unplugged Kindle, the quit confirmation during a real transfer, sleep prevention during transfers, cleanup after a cancelled upload, listing through the new transport, folder rename, and name handling for accents and special characters.

## 1.1

First public import.
