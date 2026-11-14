# DroidCopy

A small Mac app for copying files to and from an Android device over USB. It uses `adb push`
and `adb pull`, so it doesn't depend on MTP, which tends to stall or drop large files (the kind
of thing OpenMTP and Android File Transfer struggle with). It was built for moving game files to
a Retroid Pocket 5, but works with any Android device that has USB debugging on.

## What you need

- macOS 14 or later.
- `adb`. The easiest way to get it is [Homebrew](https://brew.sh):

  ```sh
  brew install android-platform-tools
  ```

  DroidCopy looks for it in `/opt/homebrew/bin`, `/usr/local/bin` and
  `~/Library/Android/sdk/platform-tools`. If yours is somewhere else, start the app with
  `DROIDCOPY_ADB=/path/to/adb`. If adb isn't found, the window shows the install command with a
  copy button.
- USB debugging turned on on the device, and the "Allow USB debugging" prompt accepted.

## Building and installing

Only the Xcode Command Line Tools are needed; full Xcode isn't.

```sh
./build-app.sh                      # builds build/DroidCopy.app (ad-hoc signed)
mv build/DroidCopy.app /Applications/
```

Each build has a new ad-hoc signature, so macOS may ask again for access to folders like
Downloads after you install a new build.

## Using it

The window works like a Finder window in list view, for the connected device.

- **Sidebar:** Favourites, then the device with its storages (Internal, SD card) and an Eject
  button. Favourites start with the usual folders the device has (`ROMs` on the card,
  Download, Documents, DCIM, Pictures, Movies and Music). Pin more with **Add to Sidebar**
  (⌃⌘T, or right-click a folder), drag them into a different order, and right-click to remove
  one. They're kept per device.
- **Getting around:** double-click a folder or press ⌘↓/⌘O. Back and Forward (⌘[ ⌘]), Enclosing
  Folder (⌘↑) and Go to Folder (⇧⌘G) work as in Finder. The first
  time, it opens the SD card, or internal storage if there's no card. After that, it opens the
  folder you were in last.
- **Search** (⌘F) narrows the folder being shown. You can also type a name to jump to it.
- **View menu:** show hidden files (⇧⌘.). The path bar (⌥⌘P) and the status bar (⌘/, item
  count and free space) are hidden unless you turn them on, as in Finder.
- **Opening files:** double-click a file to copy it to the Mac and open it there. Space shows it
  in Quick Look. Files over 1 GB aren't previewed.

If the device stops answering (an SD card busy finishing a big write, say), the folder shows
"The device isn't responding" after 20 seconds and a **Try Again** button, instead of waiting
forever.

**Copying to the device**
- Drag files or folders from Finder onto the list, or
- copy them in Finder (⌘C), click the list and paste (⌘V).

They go into the folder being shown, or into a folder if you drop them onto its row or onto a
sidebar location. Each item is selected as it arrives, so you can see what was copied. When a
batch finishes while you're in another app, you get a notification. The Dock icon shows
progress meanwhile.

**Moving and copying on the device**
- Drag items onto a folder row or a sidebar location to move them there. Hold ⌥ to copy instead.
- Or cut them (⌘X), open another folder and paste (⌘V). Cut items are shown faded until then.
- **Duplicate** (⌘D) makes "name copy", like Finder.

Name clashes are asked about first. Copies on the device use the same hidden-name-until-done
rule as copies from the Mac.

**Undo** (⌘Z) and **Redo** (⇧⌘Z) work for renames, moves, copies on the device, Duplicate and New
Folder. The Edit menu says what will be undone ("Undo Rename"). Undoing a copy removes it, but only
while the original is still there. Undoing New Folder removes the folder only if it's still empty. A
move or copy that replaced an existing item can't be undone, because the old item is gone. Deletes
can't be undone either, and copies from the Mac aren't on the list.

**Copying to the Mac**
- Drag items from the list into any Finder window or onto the Desktop. Finder asks DroidCopy for
  each item, and it is pulled straight to where you dropped it.
- Select items and press ⌘C, then paste in Finder. Finder can only paste files that already
  exist on the Mac, so ⌘C first pulls the items into `~/Library/Caches/DroidCopy/Clipboard`
  (you'll see the progress) and puts them on the clipboard when they're done. For very large
  files, dragging or **Copy to Mac…** is better because they don't make that extra copy.
- **Copy to Mac…** on the right-click menu asks for a folder and copies there.

**Paths in Terminal:** drag items into a Terminal window to type their device paths, escaped for
the shell the way Terminal does for files from Finder (`/storage/7EF7-7423/ROMs/Fire\ Emblem.nsp`).
They're ready to use in `adb shell` commands. Nothing is copied. Other apps that take dropped text
get the paths too.

**Other actions**, from the File menu, the toolbar's Action button or the right-click menu:
- **New Folder** (⇧⌘N) makes "untitled folder" and lets you name it.
- **Rename:** press Return, as in Finder, and edit the name in place.
- **Get Info** (⌘I) shows size, item count, kind and path.
- **Copy Path** (⌥⌘C) copies the device path as text.
- **Delete…** (⌘⌫ or ⌫) asks first. Android has no Trash, so a delete can't be undone.

**Ejecting:** click **Eject** (⌘E) before unplugging. It's unavailable while copies are running. It
tells the device to write everything to storage (`sync`), so nothing is lost if you switch the
device off or take the card out right after, then stops using the device. The device stays
ejected until you unplug it or click **Reconnect**. adb itself keeps running, because other apps
may be using it.

**adb's server** keeps running after DroidCopy quits, because other apps may be using it. When
none is running, DroidCopy starts it through a tiny background-only helper app inside
DroidCopy.app (`Contents/Helpers/DroidCopy adb.app`). macOS counts whatever an app starts as part
of that app, so a server started by DroidCopy itself would keep DroidCopy showing as "Running in
Background" in the Dock after it quits.

**Closing the window quits DroidCopy.** If copies are still running, it asks first: **Keep
Copying** brings the window back, and **Quit Anyway** cancels them and removes the unfinished
copies.

## How copying stays safe

- **Existing items:** if something with the same name already exists, you're asked whether to
  replace it or skip it. Nothing is overwritten without asking.
- **Hidden name until verified:** each copy is written under a hidden name (`.dc~<name>`), its
  size is checked against the source, and only then is it renamed into place. A cancelled or
  failed copy never leaves a half-written file under the real name.
- **Replacing:** the old item is kept until the new copy has been verified. The one exception is
  when the new copy only fits because the old one is deleted; then the old one is deleted first.
- **Free space** is checked before anything is copied or deleted.
- **One at a time:** transfers run in order and can be cancelled or retried from the transfer
  list. Failures stay listed until you retry or clear them, and you get one alert per batch.

## Development

```sh
swift build
swift test
```

The unit tests don't need a device. `Tests/DroidCopyTestSupport/FakeAdb.swift` is a stand-in
`adb` that runs "device" commands against a temporary folder on the Mac, so listing, copying,
replacing, free space, cancelling and failures are all tested end to end.

- `DroidCopyCoreTests` cover adb commands, parsing and the transfer queue.
- `DroidCopyAppTests` cover the app's logic: browsing, name clashes, Finder drops, ⌘C to the
  clipboard, failure alerts and the file table. They use a private clipboard and a temporary
  cache folder, so running them never touches your real clipboard.

The device tests copy real files to `/storage/emulated/0/Download/droidcopy-test` and remove
them afterwards. They run only when you name a device:

```sh
DROIDCOPY_DEVICE=<serial from `adb devices`> swift test --filter DeviceIntegrationTests
```

`SnapshotTests` renders the transfer panel to images (and a GIF of its progress bar) for showing a
change. It runs only when you give it a folder:

```sh
DROIDCOPY_SNAPSHOT_DIR=/tmp/snap swift test --filter SnapshotTests
```

**Layout**
- `Sources/DroidCopyCore`: adb commands, output parsing and the transfer queue. No UI; everything
  here is tested.
- `Sources/DroidCopy`: the SwiftUI app. `FileTableView.swift` is an AppKit table, because
  SwiftUI's `Table` can't drag files out to Finder (its drags carry only text).

**Known quirks with the Command Line Tools**
- `swift test` sometimes fails to build with "plugin for module 'TestingMacros' not found". Run
  it again, or run `swift package clean` first.
- SwiftUI's `@State` is a macro whose plugin the Command Line Tools don't include, so views use
  `@StateObject` with small `ObservableObject`s instead.
