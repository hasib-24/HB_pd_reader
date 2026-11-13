# HB Reader

Custom PDF reader: highlight, pen, eraser, sticky notes (text/image), blank pages,
note pins with images, `.hb` project files, PDF export, auto-update from GitHub.

## First run
```
flutter create --platforms=windows,linux hb_reader
cd hb_reader
# copy this folder's lib/, assets/, installer/, .github/ into the project (overwrite lib/)
flutter pub add pdfrx file_picker pasteboard pdf package_info_plus archive:^3.6.1
flutter run -d linux      # or: -d windows
```
Windows: turn on Developer Mode. Linux: `sudo apt install zenity` (file dialogs).
Bengali text in sticky notes uses the system font (Linux: install e.g. `fonts-noto`).

## Using it
- **Move** tool scrolls; wheel also works while drawing. Zoom with the toolbar.
- **Highlight**: drag a box. **Pen** (3 colors), **Eraser**, **Ctrl+Z** undo.
- **Sticky note**: toolbar button (text), **Ctrl+V** (pastes clipboard image or text),
  or "image from file". Drag the top bar to move, bottom-right corner to resize.
- **Pin** tool: click a spot, attach an image; click the numbered pin later to view it.
- **Blank pages**: toolbar page menu (insert before/after, delete blank page).
- **Ctrl+S** saves `<name>.hb` next to the PDF (autosaves 3 s after each change).
  Share the `.hb` file; anyone with HB Reader can open and edit the same notes.
- **Export PDF**: flattens everything. B/W print mode = photocopy friendly.

## Publishing + auto-update
1. Create a GitHub repo, push this project, `kRepo` in `lib/updater.dart` already points to hasib-24/HB_pd_reader.
2. Bump `version:` in `pubspec.yaml` (e.g. `0.2.0+2`), commit, then:
   `git tag v0.2.0 && git push origin v0.2.0`
3. GitHub Actions builds the Windows installer + Linux AppImage and attaches them
   to the Release. Share the repo's "Releases" link for downloading.
4. Installed apps check the latest release on start and show an update popup.

Replace `assets/icon.png` with your own icon any time.
