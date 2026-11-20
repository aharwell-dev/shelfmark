import SwiftUI
import SwiftData
import UIKit

/// A book found during a scan, before it is saved to the catalog.
struct DraftBook: Identifiable, Hashable {
    let id = UUID()
    var reading: SpineReading
    /// Normalized spine bounds in the segment image (top-left origin).
    var box: CGRect
    var measuredColorHex: String?
    var catalog: CatalogRecord?
    var include = true

    var displayTitle: String { catalog?.title.nilIfEmpty ?? reading.title.nilIfEmpty ?? "Unidentified spine" }
    var displayAuthors: String {
        let a = (catalog?.authors.isEmpty == false ? catalog!.authors : reading.authors)
        return a.joined(separator: ", ")
    }
    var colorHex: String { measuredColorHex ?? reading.primaryColor }

    static func == (l: DraftBook, r: DraftBook) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

/// One photo (or stitched panorama) of a shelf and the books found in it.
struct DraftSegment: Identifiable {
    let id = UUID()
    let image: CGImage
    let jpeg: Data
    let fromVideo: Bool
    var books: [DraftBook]
}

enum ScanInput {
    case photos([UIImage])
    case video(URL)
}

enum SaveMode: String, CaseIterable, Identifiable {
    case replace = "Replace shelf"
    case append = "Add to right end"
    var id: String { rawValue }
}

@MainActor
@Observable
final class ScanPipeline {
    enum Stage: Equatable {
        case idle, stitching, reading, identifying, cataloging, review, failed(String)

        var title: String {
            switch self {
            case .idle: return "Ready"
            case .stitching: return "Stitching video"
            case .reading: return "Reading spines"
            case .identifying: return "Identifying books"
            case .cataloging: return "Finding LC records"
            case .review: return "Review"
            case .failed: return "Something went wrong"
            }
        }
    }

    var stage: Stage = .idle
    var progress: Double = 0
    var detail: String = ""
    var segments: [DraftSegment] = []

    private let claude = ClaudeVisionService()
    private let catalog = CatalogService()

    var allBooks: [DraftBook] { segments.flatMap(\.books) }

    func reset() {
        stage = .idle; progress = 0; detail = ""; segments = []
    }

    func run(_ input: ScanInput) async {
        reset()
        do {
            var images: [(CGImage, Bool)] = []
            switch input {
            case .photos(let photos):
                images = photos.compactMap { ImageUtils.normalized($0).map { ($0, false) } }
            case .video(let url):
                stage = .stitching
                detail = "Aligning frames into a panorama…"
                images = [(try await VideoStitcher.panorama(from: url), true)]
            }

            for (index, (image, fromVideo)) in images.enumerated() {
                let books = try await identify(image, segmentLabel: images.count > 1 ? "Photo \(index + 1) of \(images.count)" : nil)
                guard let jpeg = ImageUtils.jpegData(ImageUtils.scaled(image, maxEdge: 6000)) else { continue }
                segments.append(DraftSegment(image: image, jpeg: jpeg, fromVideo: fromVideo, books: books))
            }

            try await catalogAll()
            stage = .review
        } catch {
            stage = .failed(error.localizedDescription)
        }
    }

    // MARK: Identification

    private func identify(_ image: CGImage, segmentLabel: String?) async throws -> [DraftBook] {
        let tiles = ImageUtils.horizontalTiles(image)
        stage = .reading
        detail = [segmentLabel, "Reading \(tiles.count) section\(tiles.count == 1 ? "" : "s") of the shelf"]
            .compactMap { $0 }.joined(separator: " · ")
        progress = 0

        var found: [DraftBook] = []
        var completed = 0
        let claude = self.claude

        try await withThrowingTaskGroup(of: [DraftBook].self) { group in
            var next = 0
            func addTile(_ i: Int) {
                let tile = tiles[i]
                group.addTask {
                    let hints = await SpineOCR.recognize(in: tile.image).map(\.text)
                    let small = ImageUtils.scaled(tile.image, maxEdge: 2000)
                    guard let jpeg = ImageUtils.jpegData(small, quality: 0.85) else { return [] }
                    let readings = try await claude.readSpines(jpeg: jpeg, ocrHints: hints)
                    let span = tile.x1 - tile.x0
                    return readings.map { r in
                        let x0 = tile.x0 + CGFloat(min(r.xStart, r.xEnd).clamped01) * span
                        let x1 = tile.x0 + CGFloat(max(r.xStart, r.xEnd).clamped01) * span
                        let y0 = CGFloat(min(r.yTop, r.yBottom).clamped01)
                        let y1 = CGFloat(max(r.yTop, r.yBottom).clamped01)
                        return DraftBook(reading: r, box: CGRect(x: x0, y: y0, width: max(x1 - x0, 0.002), height: max(y1 - y0, 0.05)))
                    }
                }
            }
            // At most three tiles in flight to stay polite with rate limits.
            while next < min(3, tiles.count) { addTile(next); next += 1 }
            await MainActor.run { self.stage = .identifying }
            for try await batch in group {
                found.append(contentsOf: batch)
                completed += 1
                // The task-group body isn't main-actor isolated, so hop to the main actor for UI state.
                let fraction = Double(completed) / Double(tiles.count), count = found.count
                await MainActor.run {
                    self.progress = fraction
                    self.detail = "Identified \(count) spines so far"
                }
                if next < tiles.count { addTile(next); next += 1 }
            }
        }

        var merged = Self.mergeOverlaps(found)
        for i in merged.indices {
            merged[i].measuredColorHex = ImageUtils.averageColorHex(image, normalized: merged[i].box)
        }
        return merged
    }

    /// Tiles overlap, so the same spine can be read twice. Keep the better reading.
    static func mergeOverlaps(_ books: [DraftBook]) -> [DraftBook] {
        var result: [DraftBook] = []
        for book in books.sorted(by: { $0.box.midX < $1.box.midX }) {
            if let last = result.last {
                let overlap = max(0, min(last.box.maxX, book.box.maxX) - max(last.box.minX, book.box.minX))
                let narrower = min(last.box.width, book.box.width)
                let sameTitle = !book.reading.title.isEmpty &&
                    TextMatch.score(book.reading.title, last.reading.title) > 0.7
                if overlap > narrower * 0.5 || (sameTitle && overlap > 0) {
                    if score(book) > score(last) { result[result.count - 1] = book }
                    continue
                }
            }
            result.append(book)
        }
        return result
    }

    private static func score(_ b: DraftBook) -> Double {
        // Prefer readings that are fully inside a tile (wider, more confident, titled).
        (b.reading.title.isEmpty ? 0 : 1) + b.reading.confidence + Double(b.box.width) * 2
    }

    // MARK: Cataloging

    private func catalogAll() async throws {
        stage = .cataloging
        progress = 0
        let work = segments.enumerated().flatMap { s, seg in seg.books.indices.map { (s, $0) } }
            .filter { !segments[$0.0].books[$0.1].reading.title.isEmpty }
        guard !work.isEmpty else { return }
        // Read everything the background tasks need up front, while still on the main actor.
        let jobs: [(segment: Int, book: Int, reading: SpineReading)] =
            work.map { ($0.0, $0.1, segments[$0.0].books[$0.1].reading) }
        let total = jobs.count
        let catalog = self.catalog

        await withTaskGroup(of: (Int, Int, CatalogRecord?).self) { group in
            var next = 0
            var done = 0
            func add(_ i: Int) {
                let job = jobs[i]
                let r = job.reading
                group.addTask {
                    (job.segment, job.book, await catalog.lookup(title: r.title, authors: r.authors, publisherHint: r.publisher))
                }
            }
            while next < min(4, total) { add(next); next += 1 }
            for await (s, b, record) in group {
                done += 1
                let finished = done
                await MainActor.run {
                    self.segments[s].books[b].catalog = record
                    self.progress = Double(finished) / Double(total)
                    self.detail = "Cataloged \(finished) of \(total)"
                }
                if next < total { add(next); next += 1 }
            }
        }
    }

    // MARK: Saving

    func save(to shelf: Shelf, mode: SaveMode, context: ModelContext) {
        if mode == .replace {
            for book in shelf.books { context.delete(book) }
            for photo in shelf.photos { context.delete(photo) }
        }
        var order = (mode == .append ? (shelf.photos.map(\.order).max() ?? -1) : -1) + 1

        for segment in segments {
            let photo = ShelfPhoto(order: order, imageData: segment.jpeg,
                                   pixelSize: CGSize(width: segment.image.width, height: segment.image.height),
                                   fromVideo: segment.fromVideo)
            photo.shelf = shelf
            context.insert(photo)
            order += 1

            for draft in segment.books where draft.include {
                let r = draft.reading
                let book = Book(title: draft.displayTitle == "Unidentified spine" ? "" : draft.displayTitle,
                                authorsText: draft.displayAuthors,
                                spineText: r.spineText, graphicNotes: r.graphicNotes,
                                colorHex: draft.colorHex, accentColorHex: r.accentColor,
                                confidence: r.confidence, box: draft.box, position: 0)
                if let c = draft.catalog { apply(c, to: book) }
                else { book.catalogStatus = r.title.isEmpty ? .pending : .notFound }
                if book.publisher.isEmpty { book.publisher = r.publisher }
                book.shelf = shelf
                book.photo = photo
                context.insert(book)
            }
        }
        shelf.lastScanned = .now
        // Save first so deleted books (replace mode) are gone from `shelf.books` before renumbering.
        try? context.save()
        shelf.renumberBooks()
        try? context.save()
    }
}

func apply(_ c: CatalogRecord, to book: Book) {
    if !c.title.isEmpty { book.title = c.title }
    if !c.authors.isEmpty { book.authorsText = c.authors.joined(separator: ", ") }
    if !c.publisher.isEmpty { book.publisher = c.publisher }
    book.year = c.year
    book.isbn = c.isbn
    book.lccn = c.lccn
    book.lcCallNumber = c.lcCallNumber
    book.lcClass = c.lcClass
    book.subjectsText = c.subjects.joined(separator: " | ")
    book.catalogSource = c.sources.joined(separator: " + ")
    book.catalogStatus = c.isComplete ? .matched : .partial
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension Double {
    var clamped01: Double { Swift.min(Swift.max(self, 0), 1) }
}
