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

/// Live state of one section of a shelf photo while Claude reads it.
struct TileProgress: Identifiable {
    enum Phase: Equatable { case queued, ocr, uploading, thinking, writing, done, failed }

    let id: Int
    let segment: Int
    var phase: Phase = .queued
    var ocrFragments = 0
    var titles: [String] = []
    var thought = ""
    var note = ""
    var startedAt: Date?
    var writingStartedAt: Date?
    var finishedAt: Date?

    /// Rough completion of this tile, 0–1. Claude's thinking time can't be measured directly,
    /// so it eases toward the halfway mark; writing advances with each title received.
    func fraction(at now: Date) -> Double {
        switch phase {
        case .queued: return 0
        case .ocr: return 0.04
        case .uploading: return 0.08
        case .thinking:
            let t = now.timeIntervalSince(startedAt ?? now)
            return 0.1 + 0.4 * (1 - exp(-t / 45))
        case .writing: return 0.5 + 0.45 * (1 - exp(-Double(titles.count) / 14))
        case .done, .failed: return 1
        }
    }
}

struct ActivityLine: Identifiable {
    let id = UUID()
    let time: Date
    let text: String
}

@MainActor
@Observable
final class ScanPipeline {
    enum Stage: Equatable {
        case idle, preparing, stitching, identifying, cataloging, review, failed(String)

        var title: String {
            switch self {
            case .idle: return "Waiting"
            case .preparing: return "Preparing photo"
            case .stitching: return "Stitching video"
            case .identifying: return "Identifying books"
            case .cataloging: return "Finding LC records"
            case .review: return "Ready to review"
            case .failed: return "Scan failed"
            }
        }

        var isFinished: Bool {
            switch self { case .review, .failed: return true; default: return false }
        }
    }

    var stage: Stage = .idle
    var detail: String = ""
    var segments: [DraftSegment] = []
    var tiles: [TileProgress] = []
    var catalogDone = 0
    var catalogTotal = 0
    var catalogInFlight: [String] = []
    var startedAt: Date?
    var finishedAt: Date?
    /// Last time anything happened: a stream event, a finished step. Drives the "live" indicator.
    var lastActivity: Date = .now
    var activity: [ActivityLine] = []
    var warnings: [String] = []

    private let claude = ClaudeVisionService()
    private let catalog = CatalogService()

    var allBooks: [DraftBook] { segments.flatMap(\.books) }
    var spinesSoFar: Int { tiles.reduce(0) { $0 + $1.titles.count } }

    /// Overall completion, 0–1, weighted roughly by how long each step takes.
    func progress(at now: Date = .now) -> Double {
        switch stage {
        case .idle: return 0
        case .preparing, .stitching: return 0.04
        case .identifying:
            guard !tiles.isEmpty else { return 0.08 }
            let f = tiles.reduce(0) { $0 + $1.fraction(at: now) } / Double(tiles.count)
            return 0.08 + 0.7 * f
        case .cataloging:
            return 0.78 + 0.22 * (catalogTotal == 0 ? 1 : Double(catalogDone) / Double(catalogTotal))
        case .review: return 1
        case .failed: return 0
        }
    }

    func elapsed(at now: Date = .now) -> TimeInterval {
        guard let startedAt else { return 0 }
        return (finishedAt ?? now).timeIntervalSince(startedAt)
    }

    private func log(_ text: String) {
        lastActivity = .now
        activity.append(ActivityLine(time: .now, text: text))
        if activity.count > 60 { activity.removeFirst(activity.count - 60) }
    }

    func reset() {
        stage = .idle; detail = ""; segments = []; tiles = []
        catalogDone = 0; catalogTotal = 0; catalogInFlight = []
        startedAt = nil; finishedAt = nil; activity = []; warnings = []
    }

    func run(_ input: ScanInput) async {
        reset()
        startedAt = .now
        lastActivity = .now
        do {
            var images: [(CGImage, Bool)] = []
            switch input {
            case .photos(let photos):
                stage = .preparing
                detail = photos.count == 1 ? "Straightening and sizing the photo" : "Preparing \(photos.count) photos"
                log("Started scan of \(photos.count) photo\(photos.count == 1 ? "" : "s")")
                images = await offMain { photos.compactMap { ImageUtils.normalized($0).map { ($0, false) } } }
            case .video(let url):
                stage = .stitching
                detail = "Aligning video frames into one panorama"
                log("Started stitching video")
                images = [(try await VideoStitcher.panorama(from: url), true)]
                log("Panorama ready")
            }
            try Task.checkCancellation()

            // Split every photo into sections up front so all of them can be read in parallel.
            var allTiles: [(segment: Int, image: CGImage, x0: CGFloat, x1: CGFloat)] = []
            for (s, (image, _)) in images.enumerated() {
                let parts = await offMain { ImageUtils.horizontalTiles(image) }
                allTiles += parts.map { (segment: s, image: $0.image, x0: $0.x0, x1: $0.x1) }
            }
            tiles = allTiles.enumerated().map { TileProgress(id: $0.offset, segment: $0.element.segment) }
            log("Divided into \(tiles.count) section\(tiles.count == 1 ? "" : "s") for reading")

            stage = .identifying
            detail = "Sending to Claude"
            let perSegment = try await identify(allTiles, segmentCount: images.count)

            for (s, (image, fromVideo)) in images.enumerated() {
                let merged = Self.mergeOverlaps(perSegment[s])
                let (colored, jpeg) = await offMain { () -> ([DraftBook], Data?) in
                    var books = merged
                    for i in books.indices {
                        books[i].measuredColorHex = ImageUtils.averageColorHex(image, normalized: books[i].box)
                    }
                    return (books, ImageUtils.jpegData(ImageUtils.scaled(image, maxEdge: 6000)))
                }
                guard let jpeg else { continue }
                segments.append(DraftSegment(image: image, jpeg: jpeg, fromVideo: fromVideo, books: colored))
            }
            log("Found \(allBooks.count) spines")

            try await catalogAll()
            stage = .review
            detail = "\(allBooks.count) books found"
            finishedAt = .now
            log("Finished in \(Int(elapsed()))s")
        } catch is CancellationError {
            stage = .failed("Cancelled.")
            finishedAt = .now
        } catch {
            stage = .failed(error.localizedDescription)
            finishedAt = .now
            log("Failed: \(error.localizedDescription)")
        }
    }

    // MARK: Identification

    private func identify(_ allTiles: [(segment: Int, image: CGImage, x0: CGFloat, x1: CGFloat)],
                          segmentCount: Int) async throws -> [[DraftBook]] {
        let claude = self.claude
        var results = Array(repeating: [DraftBook](), count: segmentCount)
        var failures: [String] = []

        await withTaskGroup(of: (Int, Result<[DraftBook], Error>).self) { group in
            var next = 0
            func addTile(_ i: Int) {
                let tile = allTiles[i]
                group.addTask {
                    do {
                        await self.update(i) { $0.phase = .ocr; $0.startedAt = .now }
                        let hints = await SpineOCR.recognize(in: tile.image).map(\.text)
                        await self.update(i, log: "Section \(i + 1): read \(hints.count) text fragments on device") {
                            $0.ocrFragments = hints.count; $0.phase = .uploading
                        }
                        let small = ImageUtils.scaled(tile.image, maxEdge: 2000)
                        guard let jpeg = ImageUtils.jpegData(small, quality: 0.85) else { return (i, .success([])) }

                        let readings = try await claude.readSpines(jpeg: jpeg, ocrHints: hints) { event in
                            Task { @MainActor in self.handle(event, tile: i) }
                        }
                        let span = tile.x1 - tile.x0
                        let books = readings.map { r in
                            let x0 = tile.x0 + CGFloat(min(r.xStart, r.xEnd).clamped01) * span
                            let x1 = tile.x0 + CGFloat(max(r.xStart, r.xEnd).clamped01) * span
                            let y0 = CGFloat(min(r.yTop, r.yBottom).clamped01)
                            let y1 = CGFloat(max(r.yTop, r.yBottom).clamped01)
                            return DraftBook(reading: r, box: CGRect(x: x0, y: y0, width: max(x1 - x0, 0.002), height: max(y1 - y0, 0.05)))
                        }
                        await self.update(i, log: "Section \(i + 1): \(books.count) spines identified") {
                            $0.phase = .done; $0.finishedAt = .now; $0.titles = readings.map(\.title)
                        }
                        return (i, .success(books))
                    } catch {
                        let message = error.localizedDescription
                        await self.update(i, log: "Section \(i + 1) failed: \(message)") {
                            $0.phase = .failed; $0.finishedAt = .now; $0.note = message
                        }
                        return (i, .failure(error))
                    }
                }
            }
            // At most three sections in flight to stay within rate limits.
            while next < min(3, allTiles.count) { addTile(next); next += 1 }
            for await (i, result) in group {
                switch result {
                case .success(let books): results[allTiles[i].segment].append(contentsOf: books)
                case .failure(let error): failures.append(error.localizedDescription)
                }
                if next < allTiles.count { addTile(next); next += 1 }
            }
        }

        if failures.count == allTiles.count, let first = failures.first {
            throw ClaudeError.badResponse(first)
        }
        if !failures.isEmpty {
            warnings.append("\(failures.count) of \(allTiles.count) sections couldn't be read. Books in those parts of the shelf may be missing.")
        }
        return results
    }

    private func update(_ tile: Int, log message: String? = nil, _ change: @Sendable (inout TileProgress) -> Void) {
        guard tiles.indices.contains(tile) else { return }
        change(&tiles[tile])
        lastActivity = .now
        if let message { log(message) }
    }

    private func handle(_ event: SpineStreamEvent, tile i: Int) {
        guard tiles.indices.contains(i), tiles[i].phase != .done, tiles[i].phase != .failed else { return }
        lastActivity = .now
        switch event {
        case .uploading(let bytes):
            tiles[i].phase = .uploading
            log("Section \(i + 1): sending \(bytes / 1024) KB photo to Claude")
        case .retrying(let attempt, let total, let reason):
            tiles[i].note = "Claude is \(reason); retrying (\(attempt)/\(total))"
            log("Section \(i + 1): \(tiles[i].note)")
        case .connected:
            tiles[i].phase = .thinking
            tiles[i].note = ""
            log("Section \(i + 1): Claude is examining the spines")
        case .heartbeat:
            break
        case .thinking(let text):
            if tiles[i].phase == .uploading { tiles[i].phase = .thinking }
            tiles[i].thought = text
        case .writing(let titles):
            if tiles[i].phase != .writing {
                tiles[i].phase = .writing
                tiles[i].writingStartedAt = .now
                log("Section \(i + 1): writing results")
            }
            tiles[i].titles = titles
            detail = "\(spinesSoFar) spines identified so far"
        case .fellBack:
            log("Section \(i + 1): switched to a fallback model")
        }
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
        let work = segments.enumerated().flatMap { s, seg in seg.books.indices.map { (s, $0) } }
            .filter { !segments[$0.0].books[$0.1].reading.title.isEmpty }
        catalogTotal = work.count
        catalogDone = 0
        detail = "Looking up \(work.count) books"
        log("Looking up \(work.count) books in the Library of Congress and Open Library")
        guard !work.isEmpty else { return }
        // Read everything the background tasks need up front, while still on the main actor.
        let jobs: [(segment: Int, book: Int, reading: SpineReading)] =
            work.map { ($0.0, $0.1, segments[$0.0].books[$0.1].reading) }
        let total = jobs.count
        let catalog = self.catalog

        await withTaskGroup(of: (Int, Int, String, CatalogRecord?).self) { group in
            var next = 0
            func add(_ i: Int) {
                let job = jobs[i]
                let r = job.reading
                group.addTask {
                    await MainActor.run { self.catalogInFlight.append(r.title) }
                    let record = await catalog.lookup(title: r.title, authors: r.authors, publisherHint: r.publisher)
                    return (job.segment, job.book, r.title, record)
                }
            }
            while next < min(4, total) { add(next); next += 1 }
            for await (s, b, title, record) in group {
                await MainActor.run {
                    self.segments[s].books[b].catalog = record
                    self.catalogDone += 1
                    if let k = self.catalogInFlight.firstIndex(of: title) { self.catalogInFlight.remove(at: k) }
                    self.detail = "Cataloged \(self.catalogDone) of \(total)"
                    self.lastActivity = .now
                }
                if Task.isCancelled { group.cancelAll(); break }
                if next < total { add(next); next += 1 }
            }
        }
        try Task.checkCancellation()
        let matched = allBooks.filter { $0.catalog?.lcCallNumber.isEmpty == false }.count
        log("Found LC call numbers for \(matched) of \(total)")
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

/// Runs CPU-heavy image work off the main thread so the camera and UI stay responsive.
func offMain<T>(_ work: @escaping () -> T) async -> T {
    await Task.detached(priority: .userInitiated) { work() }.value
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension Double {
    var clamped01: Double { Swift.min(Swift.max(self, 0), 1) }
}
