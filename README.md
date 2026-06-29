# pinnedelements.koplugin

A [KOReader](https://github.com/koreader/koreader) plugin that lets you pin text fragments, images, and book pages while reading — keeping them at hand for quick reference without losing your place.

Inspired by the native **Pin** feature on Kindle devices, this plugin brings a similar experience to KOReader with a richer, more flexible workflow: you can pin multiple types of content, browse all your pins in a paginated popup, sort them, zoom into pinned images, and jump back to the original page with a single tap.

Designed with **multitasking** in mind — ideal for comparing passages across different sections, cross-referencing annotations while studying, keeping key quotes visible during research, or tracking important figures and diagrams without constant back-and-forth.

> Built with vibecoding using [Claude](https://claude.ai) by Anthropic.

---

## Features

- **Pin text** — select any passage and pin it from the highlight menu with *Pin text*.
- **Pin the current page** — saves a thumbnail screenshot of the visible page.
- **Pin images** — any image opened in KOReader's image viewer gets a *Pin* button; tap it to save the image to your pin list.
- **Pin cropped screenshots** — integrates with [imagecrop.koplugin](#integration-with-imagecropkoplugin) to let you select a region of a page or image and pin only that crop.
- **Pinned Elements popup** — a scrollable, paginated list showing all pins for the current book, each with a thumbnail (for image/page pins) and a label.
- **Sort pins** — sort by page number or by creation order from the popup's menu.
- **Full-screen image viewer** — tap any pinned image to open a dedicated viewer with pan, zoom (pinch/spread or page-turn keys), and rotate. Navigate between pinned images with prev/next arrows.
- **Full text viewer** — tap a pinned text entry to read the full passage, with navigation between text pins.
- **Go to page** — from any pin detail view, jump directly back to the page in the book where the pin was created.
- **Delete pins** — remove individual pins from their detail view, or clear all pins at once from the menu.
- **Persistent storage** — pins are saved per book in KOReader's data directory and survive restarts.
- **Dispatcher integration** — the *Open Pinned Elements* action can be assigned to a gesture, hardware key, or profile via KOReader's Dispatcher.

---

## Integration with imagecrop.koplugin

When [imagecrop.koplugin](https://github.com/your-username/imagecrop.koplugin) is also installed, the image viewer gains a **Crop** button alongside the standard **Pin** button. This lets you:

1. Open any image or screenshot in the image viewer.
2. Tap **Crop** to enter two-tap crop mode — first tap sets the top-left corner, second sets the bottom-right.
3. Use the **Pin** action in the crop bar to save only the selected region directly into your pin list (no intermediate file dialog).

This workflow is especially useful for pinning a specific diagram, table, or annotation region from a full-page screenshot without cluttering your pin list with entire pages.

Both plugins communicate via `_G.PinnedElements_active`, a shared reference set automatically when a document is opened. No manual configuration is required — just install both plugins.

---

## Workflow

### Pinning text

1. Long-press any word to start a text selection.
2. Expand the selection as needed.
3. Tap **Pin text** in the highlight action bar.
4. A notification confirms the pin. The text and its page number are saved.

### Pinning the current page

1. Open the KOReader menu → **Pinned Elements** → **Pin this page**.
2. A thumbnail of the current screen is saved as a pin.

### Pinning an image

1. Tap an inline image in the book (or open a screenshot from the file browser).
2. In the image viewer, tap the **Pin** button.
3. The image is saved and a pin entry is created with the current page number as its label. If the image has a title (e.g. a screenshot filename), that title is used instead.

### Pinning a cropped region (requires imagecrop.koplugin)

1. Open an image or take a screenshot.
2. In the image viewer, tap **Crop**.
3. Tap the top-left corner of the region you want, then the bottom-right corner.
4. Tap **Pin** in the bottom bar to save only that region as a pin.

### Viewing pins

1. Open the KOReader menu → **Pinned Elements** → **View pinned elements**,  
   or use the **Pin text** / **View pins** shortcut from the highlight action bar,  
   or trigger the *Open Pinned Elements* Dispatcher action from a gesture or key.
2. The popup lists all pins for the current book. Page through them with the navigation arrows.
3. Tap any pin to open its detail view (image viewer or text viewer).
4. From the detail view, tap **Go to page** to jump back to that location in the book.
5. Tap **Delete** to remove a pin.

### Sorting

Open the popup menu (☰ icon in the title bar) to sort pins by page number or by creation order.

---

## Menu reference

**KOReader menu → Pinned Elements**

| Item | Description |
|---|---|
| Pin this page | Captures and pins the current visible page |
| View pinned elements | Opens the pins popup |
| Clear all pins (N) | Deletes all N pins for the current book |

---

## Configuration

There is no configuration file to edit. All settings are per-book and managed automatically.

To assign a gesture or hardware key to open the pins popup:

1. Go to **Menu → Gear → Profiles** (or the gesture/key assignment screen).
2. Find the action **Pinned Elements** (under *General*).
3. Assign it to any gesture or key.

---

## Installation

### Option 1 — App Store (appstore.koplugin)

The easiest way to install. [appstore.koplugin](https://github.com/omer-faruq/appstore.koplugin) must already be installed.

1. Open KOReader → **Tools → App Store**.
2. Pick the **Plugins** tab. Use the filter dialog to narrow by name.
3. Search for `PinnedElements` or `pinnedelements`.
4. Tap the entry for a quick action menu. Choosing **Install** downloads and extracts the ZIP automatically.
5. Restart KOReader.

### Option 2 — USB

1. Connect your e-reader to your computer via USB.
2. Copy the `pinnedelements.koplugin/` folder to: `/mnt/us/koreader/plugins/` (Kindle) or the equivalent `koreader/plugins/` directory on your device.
3. Restart KOReader.

### Option 3 — FilebrowserPlus (Wi-Fi, no USB cable needed)

[filebrowserplus.koplugin](https://github.com/patelneeraj/filebrowserplus.koplugin) must already be installed.

1. Open KOReader's top menu.
2. Make sure your device is connected to Wi-Fi.
3. Go to **Gear Menu → Network → FilebrowserPlus**.
4. When the server starts, you'll see the IP address and port. Visit that address (e.g., `http://192.168.x.x:8080`) from your phone or computer connected to the same Wi-Fi network.
5. You can change the password or create new users via the Filebrowser web interface.
6. Navigate to the downloaded plugin folder on your other device.
7. Copy the `pinnedelements.koplugin/` folder to: `/mnt/us/koreader/plugins/`
8. Restart KOReader.

---

## File structure

```
pinnedelements.koplugin/
├── main.lua          # Plugin entry point, pin actions, ImageViewer patch
└── pinnedpopup.lua   # Popup UI, image viewer, text viewer, pin list
```

Pins are stored in:

```
<KOReader data dir>/pinnedelements/
├── <book_filename>.lua    # Pin metadata (per book)
└── images/                # Saved thumbnails and pinned images
```

---

## Compatibility

- Tested on Kindle Paperwhite 4 with KOReader v2026.03.
- Should work on any KOReader-supported device (touch and non-touch).
- Works alongside imagecrop.koplugin, imagebookmarks.koplugin, and other plugins that patch ImageViewer.

---