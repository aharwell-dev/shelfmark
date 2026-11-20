import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// A complete, portable copy of the library: bookcases, shelves, shelf photographs and every
/// book record. Saved as JSON (photos embedded), so a backup can be read back into Shelfmark
/// on this or another iPhone.
struct LibraryArchive: Codable {
    var format = "shelfmark-library"
    var version = 1
    var exportedAt = Date()
    var bookcases: [ArchivedBookcase] = []

    struct ArchivedBookcase: Codable {
        var name, code, room: String
        var sortOrder, shelfCount: Int
        var createdAt: Date
        var shelves: [ArchivedShelf]
    }

    struct ArchivedShelf: Codable {
        var number: Int
        var lastScanned: Date?
        var contentsNote: String
        var photos: [ArchivedPhoto]
        var books: [ArchivedBook]
    }

    struct ArchivedPhoto: Codable {
        var order: Int
        var image: Data
        var pixelWidth, pixelHeight: Double
        var capturedAt: Date
        var fromVideo: Bool
    }

    struct ArchivedBook: Codable {
        var title, authorsText, spineText, graphicNotes, colorHex, accentColorHex: String
        var confidence: Double
        var publisher, year, isbn, lccn, lcCallNumber, lcClass, subjectsText: String
        var catalogSource, catalogStatusRaw, notes: String
        var subtitle, edition, publicationPlace, authorHeading, callNumberSource, catalogURL: String
        var verified: Bool
        var position: Int
        var boxX0, boxX1, boxY0, boxY1: Double
        var dateAdded: Date
        var photoOrder: Int?
    }

    var bookCount: Int { bookcases.reduce(0) { $0 + $1.shelves.reduce(0) { $0 + $1.books.count } } }

    // MARK: Building

    @MainActor
    static func make(from context: ModelContext) throws -> LibraryArchive {
        let cases = try context.fetch(FetchDescriptor<Bookcase>(sortBy: [SortDescriptor(\.sortOrder)]))
        var archive = LibraryArchive()
        archive.bookcases = cases.map { bc in
            ArchivedBookcase(
                name: bc.name, code: bc.code, room: bc.room, sortOrder: bc.sortOrder,
                shelfCount: bc.shelfCount, createdAt: bc.createdAt,
                shelves: bc.orderedShelves.map { shelf in
                    ArchivedShelf(
                        number: shelf.number, lastScanned: shelf.lastScanned, contentsNote: shelf.contentsNote,
                        photos: shelf.orderedPhotos.map {
                            ArchivedPhoto(order: $0.order, image: $0.imageData, pixelWidth: $0.pixelWidth,
                                          pixelHeight: $0.pixelHeight, capturedAt: $0.capturedAt, fromVideo: $0.fromVideo)
                        },
                        books: shelf.orderedBooks.map { b in
                            ArchivedBook(
                                title: b.title, authorsText: b.authorsText, spineText: b.spineText,
                                graphicNotes: b.graphicNotes, colorHex: b.colorHex, accentColorHex: b.accentColorHex,
                                confidence: b.confidence, publisher: b.publisher, year: b.year, isbn: b.isbn,
                                lccn: b.lccn, lcCallNumber: b.lcCallNumber, lcClass: b.lcClass,
                                subjectsText: b.subjectsText, catalogSource: b.catalogSource,
                                catalogStatusRaw: b.catalogStatusRaw, notes: b.notes, subtitle: b.subtitle,
                                edition: b.edition, publicationPlace: b.publicationPlace,
                                authorHeading: b.authorHeading, callNumberSource: b.callNumberSource,
                                catalogURL: b.catalogURL, verified: b.verified, position: b.position,
                                boxX0: b.boxX0, boxX1: b.boxX1, boxY0: b.boxY0, boxY1: b.boxY1,
                                dateAdded: b.dateAdded, photoOrder: b.photo?.order)
                        })
                })
        }
        return archive
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> LibraryArchive {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let archive = try decoder.decode(LibraryArchive.self, from: data)
        guard archive.format == "shelfmark-library" else { throw CocoaError(.fileReadCorruptFile) }
        return archive
    }

    // MARK: Restoring

    /// Adds the archive's bookcases to the library. With `replacing`, the current library is
    /// deleted first; otherwise bookcase codes that clash get a number appended (A → A2).
    @MainActor
    func restore(into context: ModelContext, replacing: Bool) throws {
        let existing = try context.fetch(FetchDescriptor<Bookcase>())
        if replacing {
            for bc in existing { context.delete(bc) }
            try context.save()
        }
        var usedCodes = Set(replacing ? [] : existing.map(\.code))
        let orderOffset = replacing ? 0 : (existing.map(\.sortOrder).max() ?? -1) + 1

        for a in bookcases {
            var code = a.code
            var n = 2
            while usedCodes.contains(code) { code = "\(a.code)\(n)"; n += 1 }
            usedCodes.insert(code)

            let bc = Bookcase(name: a.name, code: code, room: a.room, sortOrder: a.sortOrder + orderOffset,
                              shelfCount: a.shelfCount)
            bc.createdAt = a.createdAt
            context.insert(bc)

            for s in a.shelves {
                let shelf = Shelf(number: s.number)
                shelf.lastScanned = s.lastScanned
                shelf.contentsNote = s.contentsNote
                shelf.bookcase = bc
                context.insert(shelf)

                var photos: [Int: ShelfPhoto] = [:]
                for p in s.photos {
                    let photo = ShelfPhoto(order: p.order, imageData: p.image,
                                           pixelSize: CGSize(width: p.pixelWidth, height: p.pixelHeight),
                                           fromVideo: p.fromVideo)
                    photo.capturedAt = p.capturedAt
                    photo.shelf = shelf
                    context.insert(photo)
                    photos[p.order] = photo
                }
                for r in s.books {
                    let b = Book(title: r.title, authorsText: r.authorsText, spineText: r.spineText,
                                 graphicNotes: r.graphicNotes, colorHex: r.colorHex, accentColorHex: r.accentColorHex,
                                 confidence: r.confidence,
                                 box: CGRect(x: r.boxX0, y: r.boxY0, width: r.boxX1 - r.boxX0, height: r.boxY1 - r.boxY0),
                                 position: r.position)
                    b.publisher = r.publisher; b.year = r.year; b.isbn = r.isbn; b.lccn = r.lccn
                    b.lcCallNumber = r.lcCallNumber; b.lcClass = r.lcClass; b.subjectsText = r.subjectsText
                    b.catalogSource = r.catalogSource; b.catalogStatusRaw = r.catalogStatusRaw; b.notes = r.notes
                    b.subtitle = r.subtitle; b.edition = r.edition; b.publicationPlace = r.publicationPlace
                    b.authorHeading = r.authorHeading; b.callNumberSource = r.callNumberSource
                    b.catalogURL = r.catalogURL; b.verified = r.verified; b.dateAdded = r.dateAdded
                    b.shelf = shelf
                    if let order = r.photoOrder { b.photo = photos[order] }
                    context.insert(b)
                }
            }
        }
        try context.save()
    }
}

/// Wraps archive data for the system "Save to Files" sheet.
struct LibraryDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let d = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        data = d
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

// MARK: - Backup to a folder in iCloud Drive

/// Writes dated backups into a folder the user picks once (normally in iCloud Drive, so the
/// files sync to their other devices). Works with a free Apple developer account, which can't
/// use CloudKit. Keeps the ten most recent backups.
@MainActor
enum BackupManager {
    private static let bookmarkKey = "backupFolderBookmark"
    private static let lastBackupKey = "lastBackupDate"
    private static let autoKey = "autoBackup"
    private static let prefix = "Shelfmark Backup "
    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HHmm"
        return f
    }()

    static var isConfigured: Bool { UserDefaults.standard.data(forKey: bookmarkKey) != nil }
    static var lastBackup: Date? { UserDefaults.standard.object(forKey: lastBackupKey) as? Date }
    static var automatic: Bool {
        get { UserDefaults.standard.object(forKey: autoKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoKey) }
    }

    static var folderName: String? { resolveFolder()?.lastPathComponent }

    /// Remembers a folder chosen in the Files picker.
    static func setFolder(_ url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
    }

    static func clearFolder() { UserDefaults.standard.removeObject(forKey: bookmarkKey) }

    private static func resolveFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: bookmarkKey)
        }
        return url
    }

    /// Writes a backup now. Returns the file name.
    @discardableResult
    static func backUp(context: ModelContext) async throws -> String {
        guard let folder = resolveFolder() else { throw CocoaError(.fileNoSuchFile) }
        let archive = try LibraryArchive.make(from: context)
        let name = prefix + stampFormatter.string(from: Date()) + ".json"

        try await Task.detached(priority: .utility) {
            let data = try archive.encoded()
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            var coordError: NSError?
            var writeError: Error?
            NSFileCoordinator().coordinate(writingItemAt: folder.appendingPathComponent(name),
                                           options: .forReplacing, error: &coordError) { url in
                do { try data.write(to: url, options: .atomic) } catch { writeError = error }
            }
            if let e = coordError ?? writeError { throw e }
            // Keep the ten most recent backups.
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            let backups = files.filter { $0.lastPathComponent.hasPrefix("Shelfmark Backup ") }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
            for old in backups.dropFirst(10) { try? FileManager.default.removeItem(at: old) }
        }.value

        UserDefaults.standard.set(Date(), forKey: lastBackupKey)
        return name
    }

    /// Called when the app goes to the background: backs up if automatic backup is on and the
    /// last one is more than a day old.
    static func backUpIfDue(context: ModelContext) {
        guard automatic, isConfigured else { return }
        if let last = lastBackup, Date().timeIntervalSince(last) < 24 * 3600 { return }
        let token = UIApplication.shared.beginBackgroundTask(withName: "Shelfmark backup", expirationHandler: nil)
        Task { @MainActor in
            _ = try? await backUp(context: context)
            UIApplication.shared.endBackgroundTask(token)
        }
    }
}
