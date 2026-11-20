import SwiftUI
import SwiftData
import PhotosUI

// MARK: - Identify a book

/// Identifies a book the spine reader couldn't, either from a typed title and author or from a
/// photograph of the cover, title page or copyright page, then looks up its catalog record.
struct IdentifyBookView: View {
    let initialTitle: String
    let initialAuthors: String
    var spineText: String = ""
    var designNotes: String = ""
    let onUse: (CatalogRecord?, BookClues) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var authors = ""
    @State private var publisher = ""
    @State private var isbn = ""
    @State private var coverImage: UIImage?
    @State private var coverItem: PhotosPickerItem?
    @State private var status: String?
    @State private var working = false
    @State private var record: CatalogRecord?
    @State private var searched = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        Button {
                            CameraPresenter.present(photoOnly: true) { result in
                                if case .photo(let img) = result { Task { await readCover(img) } }
                            }
                        } label: {
                            Label("Photograph cover", systemImage: "camera.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        PhotosPicker(selection: $coverItem, matching: .images) {
                            Label("Choose photo", systemImage: "photo").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    if let coverImage {
                        Image(uiImage: coverImage).resizable().scaledToFit().frame(maxHeight: 160)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                } header: {
                    Text("From the cover")
                } footer: {
                    Text("The front cover, title page, or the copyright page with the ISBN all work. The copyright page identifies the edition most precisely.")
                }

                Section("Or type it in") {
                    TextField("Title", text: $title)
                    TextField("Author(s), comma separated", text: $authors)
                    TextField("Publisher (helps find the edition)", text: $publisher)
                    TextField("ISBN (optional)", text: $isbn).keyboardType(.numbersAndPunctuation)
                    Button(working ? "Searching…" : "Find catalog record") { Task { await search() } }
                        .disabled(working || (title.isEmpty && isbn.isEmpty))
                }

                if let status {
                    Section { HStack { if working { ProgressView() }; Text(status).font(.footnote) } }
                }

                if let record {
                    Section("Match") {
                        CatalogRecordSummary(record: record)
                        Button("Use this record") { onUse(record, clues); dismiss() }
                            .bold()
                    }
                } else if searched && !working {
                    Section {
                        Text("No catalog record found. You can still save the title and author you entered.")
                            .font(.footnote)
                        Button("Save without a catalog record") { onUse(nil, clues); dismiss() }
                    }
                }
            }
            .navigationTitle("Identify book")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear { title = initialTitle; authors = initialAuthors }
            .onChange(of: coverItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                        await readCover(img)
                    }
                }
            }
        }
    }

    private var clues: BookClues {
        BookClues(title: title,
                  authors: authors.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                  publisher: publisher, spineText: spineText, designNotes: designNotes,
                  isbn: isbn.filter(\.isNumber))
    }

    private func readCover(_ image: UIImage) async {
        coverImage = image
        working = true
        status = "Reading the cover…"
        defer { working = false }
        guard let cg = ImageUtils.normalized(image, maxEdge: 2000), let jpeg = ImageUtils.jpegData(cg, quality: 0.85) else { return }
        do {
            let r = try await CoverReader().identify(jpeg: jpeg)
            title = [r.title, r.subtitle].filter { !$0.isEmpty }.joined(separator: ": ")
            authors = r.authors.joined(separator: ", ")
            publisher = r.publisher
            isbn = r.isbn
            status = r.notes.isEmpty ? "Read the cover." : r.notes
            await search()
        } catch {
            status = error.localizedDescription
        }
    }

    private func search() async {
        working = true
        status = "Searching the Library of Congress and other catalogs…"
        defer { working = false; searched = true }
        record = await CatalogService().lookup(clues, deep: AppSettings.deepCatalogSearch)
        status = record == nil ? nil : "Found a record."
    }
}

/// Compact display of a catalog record for confirming a match.
struct CatalogRecordSummary: View {
    let record: CatalogRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text([record.title, record.subtitle].filter { !$0.isEmpty }.joined(separator: " : ")).bold()
            if !record.authors.isEmpty { Text(record.authors.joined(separator: ", ")).font(.subheadline) }
            Text([record.edition, record.publisher, record.year].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
            if !record.lcCallNumber.isEmpty {
                Text(record.lcCallNumber).font(Theme.mono(14, weight: .bold)).foregroundStyle(Theme.signal)
                Text(record.callNumberSource).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Subjects

/// Every book in the collection carrying a subject heading. Books whose headings share the
/// same main heading (before " -- ") are listed separately as related.
struct SubjectBooksView: View {
    let heading: String
    @Query private var books: [Book]

    var body: some View {
        let exact = books.filter { $0.subjects.contains { $0.caseInsensitiveCompare(heading) == .orderedSame } }
        let main = LCSH.main(heading)
        let related = books.filter { b in
            !exact.contains(b) && b.subjects.contains { LCSH.main($0).caseInsensitiveCompare(main) == .orderedSame }
        }
        List {
            Section {
                ForEach(sorted(exact)) { b in NavigationLink { BookDetailView(book: b) } label: { BookRow(book: b) } }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } header: {
                Text("\(exact.count) book\(exact.count == 1 ? "" : "s")")
            }
            if !related.isEmpty {
                Section("Also under “\(main)”") {
                    ForEach(sorted(related)) { b in NavigationLink { BookDetailView(book: b) } label: { BookRow(book: b) } }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.ground)
        .navigationTitle(heading)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func sorted(_ list: [Book]) -> [Book] {
        list.sorted { LCCallNumber.sortKey($0.lcCallNumber) < LCCallNumber.sortKey($1.lcCallNumber) }
    }
}

/// All subject headings in the collection with counts, grouped by main heading.
struct SubjectIndexView: View {
    @Query private var books: [Book]
    @State private var filter = ""

    var body: some View {
        var counts: [String: Int] = [:]
        for b in books { for s in b.subjects { counts[s, default: 0] += 1 } }
        let headings = counts.keys
            .filter { filter.isEmpty || $0.localizedStandardContains(filter) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return List(headings, id: \.self) { h in
            NavigationLink { SubjectBooksView(heading: h) } label: {
                HStack {
                    Text(h).font(.subheadline)
                    Spacer()
                    Text("\(counts[h] ?? 0)").font(Theme.mono(12)).foregroundStyle(Theme.inkMuted)
                }
            }
        }
        .searchable(text: $filter, prompt: "Filter subjects")
        .navigationTitle("Subjects")
        .overlay {
            if counts.isEmpty {
                ContentUnavailableView("No subject headings yet", systemImage: "tag",
                                       description: Text("Subject headings appear as books are matched to Library of Congress records."))
            }
        }
    }
}
