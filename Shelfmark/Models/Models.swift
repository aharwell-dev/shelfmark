import Foundation
import SwiftData
import CoreGraphics

// MARK: - Bookcase

/// A physical bookcase. Each bookcase has a short code ("A", "B", ...) that
/// forms the first part of every book's shelf address.
@Model
final class Bookcase {
    var name: String
    var code: String
    var room: String
    var sortOrder: Int
    var shelfCount: Int
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \Shelf.bookcase)
    var shelves: [Shelf] = []

    init(name: String, code: String, room: String = "", sortOrder: Int, shelfCount: Int) {
        self.name = name
        self.code = code
        self.room = room
        self.sortOrder = sortOrder
        self.shelfCount = shelfCount
        self.createdAt = .now
    }

    /// Shelves ordered top (1) to bottom.
    var orderedShelves: [Shelf] { shelves.sorted { $0.number < $1.number } }

    var bookCount: Int { shelves.reduce(0) { $0 + $1.books.count } }

    /// Creates or removes shelves so the case has exactly `shelfCount` shelves.
    func syncShelves(in context: ModelContext) {
        let existing = Set(shelves.map(\.number))
        for n in 1...max(shelfCount, 1) where !existing.contains(n) {
            let shelf = Shelf(number: n)
            shelf.bookcase = self
            context.insert(shelf)
        }
        for shelf in shelves where shelf.number > shelfCount && shelf.books.isEmpty {
            context.delete(shelf)
        }
    }
}

// MARK: - Shelf

/// One shelf within a bookcase, numbered from the top.
@Model
final class Shelf {
    var number: Int
    var bookcase: Bookcase?
    var lastScanned: Date?
    /// What the shelf holds when it isn't books (e.g. "Records", "Ceramics", "Empty").
    var contentsNote: String = ""

    @Relationship(deleteRule: .cascade, inverse: \ShelfPhoto.shelf)
    var photos: [ShelfPhoto] = []

    @Relationship(deleteRule: .cascade, inverse: \Book.shelf)
    var books: [Book] = []

    init(number: Int) {
        self.number = number
    }

    var orderedPhotos: [ShelfPhoto] { photos.sorted { $0.order < $1.order } }
    var orderedBooks: [Book] { books.sorted { $0.position < $1.position } }

    var label: String { "\(bookcase?.code ?? "?")-\(number)" }
    var holdsNonBooks: Bool { !contentsNote.isEmpty }

    /// Re-numbers books left to right: by photo segment, then by horizontal position in that photo.
    func renumberBooks() {
        let sorted = books.sorted {
            let a = $0.photo?.order ?? 0, b = $1.photo?.order ?? 0
            return a == b ? $0.boxX0 < $1.boxX0 : a < b
        }
        for (i, book) in sorted.enumerated() { book.position = i + 1 }
    }
}

// MARK: - ShelfPhoto

/// A photograph (or stitched video panorama) of all or part of a shelf.
/// A long shelf may be covered by several photos, ordered left to right.
@Model
final class ShelfPhoto {
    var order: Int
    @Attribute(.externalStorage) var imageData: Data
    var pixelWidth: Double
    var pixelHeight: Double
    var capturedAt: Date
    var fromVideo: Bool
    var shelf: Shelf?

    @Relationship(deleteRule: .nullify, inverse: \Book.photo)
    var books: [Book] = []

    init(order: Int, imageData: Data, pixelSize: CGSize, fromVideo: Bool) {
        self.order = order
        self.imageData = imageData
        self.pixelWidth = pixelSize.width
        self.pixelHeight = pixelSize.height
        self.capturedAt = .now
        self.fromVideo = fromVideo
    }
}

// MARK: - Book

enum CatalogStatus: String, Codable {
    case pending, matched, partial, notFound
}

@Model
final class Book {
    // Identification (from the spine)
    var title: String
    var authorsText: String
    var spineText: String
    var graphicNotes: String
    var colorHex: String
    var accentColorHex: String
    var confidence: Double

    // Catalog record (Library of Congress / Open Library)
    var publisher: String
    var year: String
    var isbn: String
    var lccn: String
    var lcCallNumber: String
    var lcClass: String
    var subjectsText: String
    var catalogSource: String
    var catalogStatusRaw: String
    var notes: String

    // Fuller LC-style record (added in v0.2; defaults keep existing catalogs readable)
    var subtitle: String = ""
    var edition: String = ""
    var publicationPlace: String = ""
    /// Main-entry heading in LC form, e.g. "Jacobs, Jane, 1916-2006".
    var authorHeading: String = ""
    /// Where the call number came from: "Library of Congress", "WorldCat", "Open Library", "Proposed (LC-style)".
    var callNumberSource: String = ""
    var catalogURL: String = ""
    /// Set when the user confirms the identification in review mode.
    var verified: Bool = false

    // Location
    var position: Int
    /// Spine bounds in the source photo, normalized 0–1 with origin at top-left.
    var boxX0: Double
    var boxX1: Double
    var boxY0: Double
    var boxY1: Double
    var shelf: Shelf?
    var photo: ShelfPhoto?

    var dateAdded: Date

    init(title: String, authorsText: String, spineText: String, graphicNotes: String,
         colorHex: String, accentColorHex: String, confidence: Double,
         box: CGRect, position: Int) {
        self.title = title
        self.authorsText = authorsText
        self.spineText = spineText
        self.graphicNotes = graphicNotes
        self.colorHex = colorHex
        self.accentColorHex = accentColorHex
        self.confidence = confidence
        self.publisher = ""
        self.year = ""
        self.isbn = ""
        self.lccn = ""
        self.lcCallNumber = ""
        self.lcClass = ""
        self.subjectsText = ""
        self.catalogSource = ""
        self.catalogStatusRaw = CatalogStatus.pending.rawValue
        self.notes = ""
        self.position = position
        self.boxX0 = box.minX
        self.boxX1 = box.maxX
        self.boxY0 = box.minY
        self.boxY1 = box.maxY
        self.dateAdded = .now
    }

    var catalogStatus: CatalogStatus {
        get { CatalogStatus(rawValue: catalogStatusRaw) ?? .pending }
        set { catalogStatusRaw = newValue.rawValue }
    }

    var box: CGRect { CGRect(x: boxX0, y: boxY0, width: boxX1 - boxX0, height: boxY1 - boxY0) }

    /// The shelf address, e.g. "B-3-07": bookcase B, third shelf from the top, seventh book from the left.
    var address: String {
        guard let shelf else { return "Unshelved" }
        return "\(shelf.bookcase?.code ?? "?")-\(shelf.number)-\(String(format: "%02d", position))"
    }

    /// A spoken-style version of the address for the finding aid.
    var addressDescription: String {
        guard let shelf, let bookcase = shelf.bookcase else { return "Not yet shelved" }
        let room = bookcase.room.isEmpty ? "" : " in \(bookcase.room)"
        return "\(bookcase.name)\(room), shelf \(shelf.number) from the top, book \(position) from the left"
    }

    /// A compact title for spine drawings: drops a leading article and any subtitle.
    var shortTitle: String {
        var t = title.isEmpty ? "Unidentified" : title
        if let colon = t.firstIndex(where: { $0 == ":" || $0 == ";" }) { t = String(t[..<colon]) }
        for article in ["The ", "A ", "An "] where t.hasPrefix(article) && t.count > article.count + 3 {
            t = String(t.dropFirst(article.count))
        }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// Surname of the first author, for the foot of a drawn spine.
    var authorSurname: String {
        if !authorHeading.isEmpty, let comma = authorHeading.firstIndex(of: ",") {
            return String(authorHeading[..<comma])
        }
        let first = authorsText.split(separator: ",").first.map(String.init) ?? authorsText
        return first.split(separator: " ").last.map(String.init) ?? ""
    }

    var isUnidentified: Bool { title.isEmpty || catalogStatus == .pending }

    var subjects: [String] {
        subjectsText.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Text used for search: everything a person might type.
    var searchBlob: String {
        [title, subtitle, authorsText, authorHeading, spineText, publisher, edition, year, isbn, lccn, lcCallNumber, subjectsText, address, notes]
            .joined(separator: " ")
    }

    /// Relative width used when drawing this spine in the finding aid.
    var drawingWidth: Double {
        let w = max(boxX1 - boxX0, 0.004)
        guard let photo, photo.pixelHeight > 0 else { return w * 4 }
        // Express spine width relative to photo height so books from different photos compare fairly.
        return w * photo.pixelWidth / photo.pixelHeight
    }
}
