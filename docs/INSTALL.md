# Installing Ledger Atlas on your Mac

Ledger Atlas is a free, open-source Mac app. It is not sold through the App Store and is not
notarized by Apple, so macOS asks you to approve it once. These steps take about two minutes.

**You need:** macOS 15 (Sequoia) or later.

## 1. Download

1. Open the [Releases page](https://github.com/praxstack/ledger-atlas/releases) and pick the
   newest release.
2. Download `LedgerAtlas-<version>.dmg` and the matching `.sha256` file.
3. Optional but recommended: check the download is intact. In Terminal, in your Downloads folder:

   ```sh
   shasum -a 256 -c LedgerAtlas-<version>.dmg.sha256
   ```

   It should print `OK`.

## 2. Install

1. Double-click the DMG.
2. Drag **Ledger Atlas** onto the **Applications** shortcut.
3. Eject the DMG.

## 3. Open it the first time

macOS blocks apps that are not notarized the first time you open them.

1. Open **Ledger Atlas** from Applications. macOS says it can't verify the app. Click **Done**.
2. Open **System Settings › Privacy & Security**, scroll to **Security**, and click
   **Open Anyway** next to the Ledger Atlas message. Confirm with your password or Touch ID.
3. Open Ledger Atlas again and click **Open** (or **Open Anyway**).

You only do this once per version. (Right-click › Open no longer skips this on macOS 15.)

## Bring in your Money Manager data

Click **Import** in the toolbar (or **File › Import Money Manager Backup…**, ⇧⌘I). Pick the backup's time zone, choose the `.mmbak` file, check the review, then
approve it. The new ledger opens by itself.

**Open Ledger…** is for Ledger Atlas ledgers. If you pick a Money Manager backup there, the
app offers to import it instead.

## The widget

The free (ad-hoc signed) build can't share data with its widget: macOS only allows that for apps
signed with a paid developer account. The widget shows "Open Ledger Atlas to continue." and the app works
normally without it.

## Where your ledgers live

Ledgers live **inside the app's own storage**, not in a folder you pick:

```
~/Library/Containers/com.praxstack.ledgeratlas/Data/Library/Application Support/Ledger Atlas/Ledgers/
```

- macOS's App Sandbox only lets the app keep a ledger's journal file in its own storage, so
  this is the one place a ledger can be safely edited.
- **Opening a ledger from somewhere else copies it in.** The original file is left untouched.
- **Importing a Money Manager backup** builds a new ledger here. The backup file itself is only read.
- **Don't move, rename or edit files in that folder by hand.** Use the app's **Backup** screen.
- Time Machine backs this folder up along with the rest of your home folder.

## Passcode and receipt keys

Ledger Atlas keeps two small secrets: the app-lock passcode (only a salted verifier, never the
passcode itself) and the keys that let the app check its own import receipts.

- By default they are private files that only your Mac account can read, in the same app
  storage (`…/Application Support/Ledger Atlas/Keys` and `…/AppLock`).
- **Settings › Privacy › Keep passcode and receipt keys in** can move them to this Mac's
  Keychain instead. Because the free app is signed differently in every version, macOS then
  asks for your Mac password after each update before Ledger Atlas can read them.
- Either way they stay on this Mac. They are never inside a ledger or a backup file.
- The app lock hides the open ledger. It does not encrypt ledger files on disk.

## Backups

On the **Backup** screen:

- **Save 1:1 backup…** writes an exact copy of the open ledger to a place you choose.
  Use this for regular backups and before big changes.
- **Restore backup…** shows what the backup holds, then builds a new ledger from it. With a
  ledger open you choose **Replace open ledger** or **Merge into open ledger…**. Either way the
  current ledger file is kept, so you can go back to it.
- Backups are not encrypted in v1. Store them somewhere private.

### Moving to another Mac

A ledger with imported Money Manager history is checked with its receipt key, and that key
stays on the Mac that imported it (see above). On a new Mac, or after the `Keys` folder is
lost, the ledger itself is fine, but Ledger Atlas can't check it without the key.

- With the ledger open, choose **Save recovery key…** on the Backup screen once. Keep the
  `.ledgerkey` file **separate from your backups**, ideally in a password manager: the key is
  what shows that imported history wasn't changed, so anyone holding both a backup and its key
  could alter that history without it showing.
- On the other Mac, open or restore the ledger. When Ledger Atlas says the receipt key isn't
  on this Mac, choose **Choose Recovery Key…** and pick that file. The key is checked against
  the ledger before it is added, and never replaces a different key.
- A ledger you made in Ledger Atlas without importing needs no key.
- No recovery key saved? If the keys were kept as files (the default) and the old Mac is in a
  Time Machine backup, restoring that Mac's `…/Application Support/Ledger Atlas/Keys` folder
  brings them back. Restore it only where that folder is missing or empty: never over a `Keys`
  folder holding other keys. Keys kept in the Keychain stay on the old Mac and can't be
  restored this way, so save a recovery key there.

## Updating

Download the new DMG and drag the new **Ledger Atlas** into Applications, replacing the old
one. Your ledgers stay where they are. Approve the new version once in
**Privacy & Security**, as in step 3.

## Uninstalling

1. Drag **Ledger Atlas** from Applications to the Trash.
2. Your ledgers are **not** deleted. To remove them too, first save any backups you want, then delete
   `~/Library/Containers/com.praxstack.ledgeratlas`.

## Something went wrong?

Open an issue at <https://github.com/praxstack/ledger-atlas/issues>. Never attach a ledger
or a Money Manager backup: they contain your financial data.
