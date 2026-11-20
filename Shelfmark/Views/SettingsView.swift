import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Environment(Router.self) private var router
    @Query(sort: \Bookcase.sortOrder) private var bookcases: [Bookcase]
    @Query private var books: [Book]

    @State private var apiKey = AppSettings.apiKey
    @State private var model = AppSettings.model
    @State private var effort = AppSettings.effort
    @State private var editingCase: Bookcase?
    @State private var addingCase = false
    @State private var exportURL: URL?
    @State private var recataloging = false
    @State private var recatalogProgress = 0
    @State private var deepSearch = AppSettings.deepCatalogSearch
    @State private var recoloring = false
    @State private var exportDoc: LibraryDocument?
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var pendingImport: LibraryArchive?
    @State private var pickingFolder = false
    @State private var autoBackup = BackupManager.automatic
    @State private var backupStatus: String?
    @State private var backingUp = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(bookcases) { bc in
                        Button { editingCase = bc } label: {
                            HStack {
                                Text(bc.code).font(Theme.display(24)).foregroundStyle(Theme.signal).frame(width: 40, alignment: .leading)
                                VStack(alignment: .leading) {
                                    Text(bc.name).foregroundStyle(Theme.ink)
                                    Text("\(bc.shelfCount) shelves · \(bc.bookCount) books\(bc.room.isEmpty ? "" : " · \(bc.room)")")
                                        .font(.caption).foregroundStyle(Theme.inkMuted)
                                }
                            }
                        }
                    }
                    .onDelete { idx in
                        for i in idx {
                            if router.highlighted?.shelf?.bookcase == bookcases[i] { router.highlighted = nil }
                            context.delete(bookcases[i])
                        }
                        try? context.save()
                    }
                    .onMove { from, to in
                        var ordered = bookcases
                        ordered.move(fromOffsets: from, toOffset: to)
                        for (i, bc) in ordered.enumerated() { bc.sortOrder = i }
                    }
                    Button { addingCase = true } label: { Label("Add bookcase", systemImage: "plus") }
                } header: {
                    Text("Bookcases")
                } footer: {
                    Text("Bookcases appear in the finding aid in this order. Drag to match how they stand in the room.")
                }

                Section {
                    SecureField("sk-ant-…", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: apiKey) { _, v in AppSettings.apiKey = v }
                    TextField("Model", text: $model)
                        .font(Theme.mono(14))
                        .textInputAutocapitalization(.never)
                        .onChange(of: model) { _, v in AppSettings.model = v }
                    Picker("Effort", selection: $effort) {
                        Text("Low (fast)").tag("low")
                        Text("Medium").tag("medium")
                        Text("High (most accurate)").tag("high")
                    }
                    .onChange(of: effort) { _, v in AppSettings.effort = v }
                } header: {
                    Text("Spine recognition (Claude)")
                } footer: {
                    Text("Shelf photos are sent to the Claude API to identify spines. Your key is stored in the iOS Keychain on this device only.")
                }

                Section {
                    Toggle(isOn: $deepSearch) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Research unmatched books online")
                            Text("Claude searches library catalogs, WorldCat and publisher records when the Library of Congress lookup comes up short. Slower, and uses a little more of your API credit.")
                                .font(.caption).foregroundStyle(Theme.inkMuted)
                        }
                    }
                    .onChange(of: deepSearch) { _, v in AppSettings.deepCatalogSearch = v }
                    Button {
                        Task { await recatalog() }
                    } label: {
                        Label(recataloging ? "Looking up… \(recatalogProgress)" : "Look up all unmatched books again",
                              systemImage: "building.columns")
                    }
                    .disabled(recataloging)
                    Button {
                        Task { await recomputeColors() }
                    } label: {
                        Label(recoloring ? "Measuring colors…" : "Remeasure spine colors from photos", systemImage: "paintpalette")
                    }
                    .disabled(recoloring)
                    Button { exportURL = CatalogExport.csv(books) } label: {
                        Label("Export catalog as spreadsheet (CSV)", systemImage: "tablecells")
                    }
                    if let exportURL {
                        ShareLink(item: exportURL) { Label("Share \(exportURL.lastPathComponent)", systemImage: "doc.text") }
                    }
                } header: {
                    Text("Catalog")
                }

                Section {
                    Button {
                        do {
                            let archive = try LibraryArchive.make(from: context)
                            exportDoc = LibraryDocument(data: try archive.encoded())
                            showExporter = true
                        } catch { message = "Export failed: \(error.localizedDescription)" }
                    } label: {
                        Label("Export library to a file", systemImage: "square.and.arrow.up")
                    }
                    Button { pickingFolder = false; showImporter = true } label: {
                        Label("Import a library file", systemImage: "square.and.arrow.down")
                    }
                } header: {
                    Text("Library file")
                } footer: {
                    Text("A library file holds everything: bookcases, shelves, shelf photos and every catalog record. Use it to move your library to another iPhone or keep a copy.")
                }

                Section {
                    if BackupManager.isConfigured {
                        LabeledContent("Folder", value: BackupManager.folderName ?? "Unavailable")
                        Toggle("Back up automatically (daily)", isOn: $autoBackup)
                            .onChange(of: autoBackup) { _, v in BackupManager.automatic = v }
                        Button {
                            Task { await backUpNow() }
                        } label: {
                            Label(backingUp ? "Backing up…" : "Back up now", systemImage: "icloud.and.arrow.up")
                        }
                        .disabled(backingUp)
                        if let last = BackupManager.lastBackup {
                            LabeledContent("Last backup", value: last.formatted(date: .abbreviated, time: .shortened))
                        }
                        Button("Choose a different folder") { pickingFolder = true; showImporter = true }
                    } else {
                        Button { pickingFolder = true; showImporter = true } label: {
                            Label("Choose an iCloud Drive folder", systemImage: "icloud")
                        }
                    }
                    if let backupStatus { Text(backupStatus).font(.caption).foregroundStyle(Theme.inkMuted) }
                } header: {
                    Text("iCloud backup")
                } footer: {
                    Text("Pick or create a folder in iCloud Drive (for example iCloud Drive › Shelfmark). Backups are saved there and sync to your other devices; the ten most recent are kept. To restore, use Import a library file and choose a backup.")
                }

                Section("About") {
                    LabeledContent("Books", value: "\(books.count)")
                    LabeledContent("Address format", value: "Case–Shelf–Position")
                    Text("Addresses read bookcase, shelf counted from the top, then position counted from the left. B-3-07 is the seventh book on the third shelf of bookcase B.")
                        .font(.caption).foregroundStyle(Theme.inkMuted)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.ground)
            .navigationTitle("Settings")
            .toolbar { EditButton() }
            .fileExporter(isPresented: $showExporter, document: exportDoc, contentType: .json,
                          defaultFilename: "Shelfmark Library \(Date().formatted(.iso8601.year().month().day()))") { result in
                if case .failure(let e) = result { message = "Export failed: \(e.localizedDescription)" }
            }
            // One importer serves both jobs (SwiftUI honors only one fileImporter per view).
            .fileImporter(isPresented: $showImporter, allowedContentTypes: pickingFolder ? [.folder] : [.json]) { result in
                switch result {
                case .success(let url) where pickingFolder:
                    do {
                        try BackupManager.setFolder(url)
                        backupStatus = "Backups will be saved to “\(url.lastPathComponent)”."
                        Task { await backUpNow() }
                    } catch { backupStatus = "Couldn't use that folder: \(error.localizedDescription)" }
                case .success(let url):
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    do { pendingImport = try LibraryArchive.decode(Data(contentsOf: url)) }
                    catch { message = "That file isn't a Shelfmark library." }
                case .failure(let e):
                    message = e.localizedDescription
                }
            }
            .confirmationDialog("Import \(pendingImport?.bookCount ?? 0) books in \(pendingImport?.bookcases.count ?? 0) bookcases?",
                                isPresented: Binding(get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } }),
                                titleVisibility: .visible) {
                Button("Add to my library") { runImport(replacing: false) }
                Button("Replace my library", role: .destructive) { runImport(replacing: true) }
            } message: {
                Text("Adding keeps your current bookcases; clashing bookcase codes get a number added. Replacing deletes the current library first.")
            }
            .alert("Shelfmark", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK") { message = nil }
            } message: { Text(message ?? "") }
            .sheet(item: $editingCase) { bc in BookcaseEditor(bookcase: bc, nextOrder: bookcases.count) { _ in } }
            .sheet(isPresented: $addingCase) { BookcaseEditor(bookcase: nil, nextOrder: bookcases.count) { _ in } }
        }
    }

    private func recatalog() async {
        recataloging = true
        defer { recataloging = false }
        let service = CatalogService()
        let pending = books.filter { $0.catalogStatus != .matched && !$0.title.isEmpty }
        for book in pending {
            let clues = BookClues(title: book.title,
                                  authors: book.authorsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) },
                                  publisher: book.publisher, spineText: book.spineText,
                                  designNotes: book.graphicNotes, isbn: book.isbn)
            if let r = await service.lookup(clues, deep: AppSettings.deepCatalogSearch) { apply(r, to: book) }
            else { book.catalogStatus = .notFound }
            recatalogProgress += 1
            try? context.save()
        }
        recatalogProgress = 0
    }

    /// Re-measures every spine's color from its shelf photo with the current method.
    private func recomputeColors() async {
        recoloring = true
        defer { recoloring = false }
        let photos = (try? context.fetch(FetchDescriptor<ShelfPhoto>())) ?? []
        for photo in photos where !photo.books.isEmpty {
            let data = photo.imageData
            let boxes = photo.books.map(\.box)
            let colors: [String?] = await offMain {
                guard let ui = UIImage(data: data), let cg = ui.cgImage else { return boxes.map { _ in nil } }
                return boxes.map { ImageUtils.averageColorHex(cg, normalized: $0) }
            }
            for (book, color) in zip(photo.books, colors) { if let color { book.colorHex = color } }
        }
        try? context.save()
        message = "Spine colors updated for \(books.count) books."
    }

    private func backUpNow() async {
        backingUp = true
        defer { backingUp = false }
        do {
            let name = try await BackupManager.backUp(context: context)
            backupStatus = "Saved “\(name)”."
        } catch {
            backupStatus = "Backup failed: \(error.localizedDescription)"
        }
    }

    @MainActor private func runImport(replacing: Bool) {
        guard let archive = pendingImport else { return }
        pendingImport = nil
        if replacing { router.highlighted = nil }
        do {
            try archive.restore(into: context, replacing: replacing)
            message = "Imported \(archive.bookCount) books."
        } catch {
            message = "Import failed: \(error.localizedDescription)"
        }
    }
}

/// Create or edit a bookcase.
struct BookcaseEditor: View {
    let bookcase: Bookcase?
    let nextOrder: Int
    let onSave: (Bookcase) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var code = ""
    @State private var room = ""
    @State private var shelves = 5

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (e.g. Living room, left)", text: $name)
                    TextField("Code", text: $code)
                        .textInputAutocapitalization(.characters)
                        .font(Theme.mono(17, weight: .bold))
                    TextField("Room (optional)", text: $room)
                    Stepper("Shelves: \(shelves)", value: $shelves, in: 1...14)
                } footer: {
                    Text("The code is the first part of every address on this bookcase. Keep it short: A, B, C… or LR1, ST2.")
                }
                Section("Preview") {
                    HStack {
                        AddressBadge(address: "\(code.isEmpty ? "A" : code)-1-01", large: true)
                        Spacer()
                        Text("first book, top shelf").font(.caption).foregroundStyle(Theme.inkMuted)
                    }
                }
            }
            .navigationTitle(bookcase == nil ? "New bookcase" : "Edit bookcase")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(code.isEmpty) }
            }
            .onAppear {
                if let bc = bookcase {
                    name = bc.name; code = bc.code; room = bc.room; shelves = bc.shelfCount
                } else {
                    code = String(Character(UnicodeScalar(UInt8(65 + min(nextOrder, 25)))))
                    name = "Bookcase \(code)"
                }
            }
        }
    }

    private func save() {
        let cleanCode = code.trimmingCharacters(in: .whitespaces).uppercased().replacingOccurrences(of: "-", with: "")
        let bc: Bookcase
        if let existing = bookcase {
            bc = existing
            bc.name = name; bc.code = cleanCode; bc.room = room; bc.shelfCount = shelves
        } else {
            bc = Bookcase(name: name.isEmpty ? "Bookcase \(cleanCode)" : name, code: cleanCode, room: room,
                          sortOrder: nextOrder, shelfCount: shelves)
            context.insert(bc)
        }
        bc.syncShelves(in: context)
        try? context.save()
        onSave(bc)
        dismiss()
    }
}

enum CatalogExport {
    static func csv(_ books: [Book]) -> URL? {
        let header = ["Address", "Title", "Subtitle", "Authors", "Main Entry", "Edition", "Place", "Publisher", "Year",
                      "LC Call Number", "LC Class", "Call Number Source", "ISBN", "LCCN", "Subjects",
                      "Bookcase", "Room", "Shelf", "Position", "Catalog Status", "Confirmed", "Notes"]
        func esc(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let sorted = books.sorted { LCCallNumber.sortKey($0.lcCallNumber) < LCCallNumber.sortKey($1.lcCallNumber) }
        var lines = [header.map(esc).joined(separator: ",")]
        for b in sorted {
            lines.append([b.address, b.title, b.subtitle, b.authorsText, b.authorHeading, b.edition,
                          b.publicationPlace, b.publisher, b.year, b.lcCallNumber, b.lcClass, b.callNumberSource,
                          b.isbn, b.lccn, b.subjectsText, b.shelf?.bookcase?.name ?? "", b.shelf?.bookcase?.room ?? "",
                          "\(b.shelf?.number ?? 0)", "\(b.position)", b.catalogStatusRaw, b.verified ? "yes" : "no", b.notes]
                .map(esc).joined(separator: ","))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Shelfmark-catalog.csv")
        do { try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8); return url }
        catch { return nil }
    }
}
