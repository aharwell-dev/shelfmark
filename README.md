# Shelfmark

An iPhone app that catalogs a home library from photographs. Point the camera at a shelf, or pan along it with video. Shelfmark reads every spine, identifies each book from its lettering, colors, and graphic design, looks up the Library of Congress record, and gives every book a shelf address. Searching the catalog brings up a visual finding aid: an elevation drawing of every bookcase in the collection, with the book you want lit up in place.

## How it works

| Stage | What happens | Where |
|---|---|---|
| Capture | Still photos (one or several sections of a shelf, left to right) or a video pan. Video frames are aligned with Vision's image registration and stitched into one panorama. | `VideoStitcher.swift` |
| Read | On-device OCR (Apple Vision) reads spine text in three orientations. The results go to the vision model as hints. | `SpineOCR.swift` |
| Identify | Wide shelves are cut into overlapping tiles. Each tile goes to Claude with a prompt that asks it to identify every spine left to right from typography, color, series design, and publisher marks, and to return the spine's bounds and colors as structured JSON. Duplicate readings from the tile overlaps are merged. | `ClaudeVisionService.swift`, `ScanPipeline.swift` |
| Catalog | Open Library search (tolerant of partial titles) supplies the ISBN, LCCN, and LCC. The loc.gov JSON API then supplies the authoritative LC call number and subject headings. | `CatalogService.swift` |
| Review | The shelf photo is shown with each detected spine outlined and numbered. Misread spines can be corrected and looked up again, or excluded. | `ScanSessionView.swift` |
| Shelve | Each book gets an address, **Case–Shelf–Position**: `B-3-07` is bookcase B, third shelf from the top, seventh book from the left. | `Models.swift` |
| Find | **Plan** mode draws every bookcase as an elevation. Spines are drawn to scale in their photographed colors; the target pulses with a flag over it and everything else is dimmed. **Photo** mode shows the book in the original shelf photo with the rest of the image darkened. | `FindingAidView.swift` |

The catalog can be searched by title, author, subject, LC call number, ISBN, spine text, or address, and sorted in LC shelf order. It exports to CSV.

## Building

You need a Mac with Xcode 15 or later and an iPhone running iOS 17 or later.

1. Install [XcodeGen](https://github.com/yonaskolb/XcodeGen):
   ```bash
   brew install xcodegen
   ```
2. Generate the Xcode project from the repository root:
   ```bash
   xcodegen generate
   ```
3. Open the project:
   ```bash
   open Shelfmark.xcodeproj
   ```
4. In the target's **Signing & Capabilities** tab, choose your team. A free Apple ID works for installing on your own phone.
5. Plug in the iPhone, select it as the run destination, and press Run.
6. In the app, open **Settings** and paste in a Claude API key (from console.anthropic.com).

The camera does not work in the Simulator. To test there, use **Library** and pick shelf photos you have dragged into the Simulator's Photos app.

## Notes and limits

- **API key.** The key is stored in the iOS Keychain and sent only to `api.anthropic.com`. That is fine for personal use. Before distributing the app to other people, move the Claude call behind a small server so the key never ships on a device.
- **Cost.** Each tile of a shelf photo is one Claude request. A typical shelf comes to two to four requests. In Settings, Effort can be set to Low for faster, cheaper scans or High for the most accurate identification.
- **LC coverage.** Books without an LC record (many trade paperbacks, exhibition catalogs, small-press and foreign titles) are kept and marked "No LC record". You can add a call number by hand, or retry the lookup later from Settings.
- **Video.** Stitching works best with a slow, level pan at a constant distance. If a panorama comes out poorly, photographing the shelf in sections with **Add to right end** gives more reliable results.
- **Not yet compiled.** This code was written without access to Xcode. Expect a round of small compile fixes the first time you build it.
