import SwiftUI
import SwiftData

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

                Section("Catalog") {
                    Button {
                        Task { await recatalog() }
                    } label: {
                        Label(recataloging ? "Looking up… \(recatalogProgress)" : "Retry LC lookup for unmatched books",
                              systemImage: "building.columns")
                    }
                    .disabled(recataloging)
                    Button { exportURL = CatalogExport.csv(books) } label: {
                        Label("Export catalog (CSV)", systemImage: "square.and.arrow.up")
                    }
                    if let exportURL {
                        ShareLink(item: exportURL) { Label("Share \(exportURL.lastPathComponent)", systemImage: "doc.text") }
                    }
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
            let authors = book.authorsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if let r = await service.lookup(title: book.title, authors: authors) { apply(r, to: book) }
            else { book.catalogStatus = .notFound }
            recatalogProgress += 1
        }
        recatalogProgress = 0
        try? context.save()
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
        let header = ["Address", "Title", "Authors", "LC Call Number", "LC Class", "Publisher", "Year",
                      "ISBN", "LCCN", "Subjects", "Bookcase", "Room", "Shelf", "Position", "Catalog Status", "Notes"]
        func esc(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let sorted = books.sorted { LCCallNumber.sortKey($0.lcCallNumber) < LCCallNumber.sortKey($1.lcCallNumber) }
        var lines = [header.map(esc).joined(separator: ",")]
        for b in sorted {
            lines.append([b.address, b.title, b.authorsText, b.lcCallNumber, b.lcClass, b.publisher, b.year,
                          b.isbn, b.lccn, b.subjectsText, b.shelf?.bookcase?.name ?? "", b.shelf?.bookcase?.room ?? "",
                          "\(b.shelf?.number ?? 0)", "\(b.position)", b.catalogStatusRaw, b.notes]
                .map(esc).joined(separator: ","))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Shelfmark-catalog.csv")
        do { try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8); return url }
        catch { return nil }
    }
}
