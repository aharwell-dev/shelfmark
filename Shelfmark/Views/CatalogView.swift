import SwiftUI
import SwiftData

/// The searchable catalog. Keyword search filters instantly across every field; "Ask" sends a
/// natural-language request to Claude, which reads the whole catalog and explains each match.
struct CatalogView: View {
    @Query private var books: [Book]
    @Query(sort: \Bookcase.sortOrder) private var bookcases: [Bookcase]
    @Environment(Router.self) private var router
    @Environment(\.modelContext) private var context
    @State private var query = ""
    @State private var sort: SortOrder = .callNumber
    @State private var layout: Layout = .list
    @State private var mode: SearchMode = .keyword
    @State private var aiHits: [AIHit] = []
    @State private var aiInterpretation = ""
    @State private var aiWorking = false
    @State private var aiError: String?
    @State private var pendingDelete: Book?

    enum SortOrder: String, CaseIterable, Identifiable {
        case callNumber = "Call no.", title = "Title", author = "Author", location = "Location", recent = "Recent"
        var id: String { rawValue }
    }
    enum Layout { case list, spines }
    enum SearchMode: String, CaseIterable, Identifiable {
        case keyword = "Keyword", ask = "Ask"
        var id: String { rawValue }
    }

    private var results: [Book] {
        let terms = query.split(separator: " ").map(String.init)
        let filtered = terms.isEmpty ? books : books.filter { book in
            let blob = book.searchBlob
            return terms.allSatisfy { blob.localizedStandardContains($0) }
        }
        switch sort {
        case .callNumber: return filtered.sorted { LCCallNumber.sortKey($0.lcCallNumber) < LCCallNumber.sortKey($1.lcCallNumber) }
        case .title: return filtered.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .author: return filtered.sorted { $0.authorsText.localizedStandardCompare($1.authorsText) == .orderedAscending }
        case .location: return filtered.sorted { locationKey($0) < locationKey($1) }
        case .recent: return filtered.sorted { $0.dateAdded > $1.dateAdded }
        }
    }

    private func locationKey(_ b: Book) -> String {
        let order = b.shelf?.bookcase?.sortOrder ?? 999
        return String(format: "%04d-%03d-%04d", order, b.shelf?.number ?? 0, b.position)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.ground.ignoresSafeArea()
                if books.isEmpty {
                    EmptyCatalog { router.tab = .scan }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            Picker("Search", selection: $mode) {
                                Text("Keyword").tag(SearchMode.keyword)
                                Label("Ask", systemImage: "sparkles").tag(SearchMode.ask)
                            }
                            .pickerStyle(.segmented)

                            if mode == .ask {
                                askResults
                            } else {
                                StatsStrip(books: books, bookcases: bookcases)
                                controls
                                if layout == .list {
                                    LazyVStack(spacing: 10) {
                                        ForEach(results) { book in row(book) }
                                    }
                                } else {
                                    SpineWall(books: results)
                                }
                                if results.isEmpty {
                                    Text("No books match “\(query)”. Try Ask to search by meaning.")
                                        .foregroundStyle(Theme.inkMuted)
                                        .frame(maxWidth: .infinity)
                                        .padding(.top, 40)
                                }
                            }
                        }
                        .padding(.horizontal)
                        .padding(.bottom, 30)
                    }
                }
            }
            .navigationTitle("Catalog")
            .navigationDestination(for: Book.self) { BookDetailView(book: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { SubjectIndexView() } label: { Label("Subjects", systemImage: "tag") }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: mode == .ask ? "Ask, e.g. books on housing in New Haven" : "Title, author, subject, call number…")
            .onSubmit(of: .search) {
                if mode == .ask {
                    Task { await askAI() }
                } else if results.count == 1, let only = results.first {
                    // A keyword search that matches exactly one book jumps straight to its location.
                    router.find(only)
                }
            }
            .onChange(of: mode) { _, new in
                if new == .ask, !query.isEmpty, aiHits.isEmpty { Task { await askAI() } }
            }
            .confirmationDialog("Delete “\(pendingDelete?.title ?? "")” from the catalog?",
                                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let b = pendingDelete { deleteBook(b, context: context, router: router) }
                    pendingDelete = nil
                }
            }
        }
    }

    private func row(_ book: Book, reason: String? = nil) -> some View {
        NavigationLink(value: book) {
            VStack(alignment: .leading, spacing: 0) {
                BookRow(book: book, query: query)
                if let reason {
                    Text(reason).font(.caption).foregroundStyle(Theme.inkMuted)
                        .padding(.horizontal, 14).padding(.top, -4).padding(.bottom, 8)
                }
            }
            .background(reason == nil ? Color.clear : Theme.panel, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { router.find(book) } label: { Label("Show on shelf", systemImage: "scope") }
            if let shelf = book.shelf {
                Button { router.reviewShelf = shelf } label: { Label("Review shelf", systemImage: "checkmark.circle") }
            }
            Button(role: .destructive) { pendingDelete = book } label: { Label("Delete", systemImage: "trash") }
        }
    }

    @ViewBuilder private var askResults: some View {
        if aiWorking {
            HStack(spacing: 10) {
                ProgressView()
                Text("Reading your catalog…").foregroundStyle(Theme.inkMuted)
            }
            .frame(maxWidth: .infinity).padding(.top, 30)
        } else if let aiError {
            Label(aiError, systemImage: "exclamationmark.triangle").foregroundStyle(.yellow).font(.footnote)
        } else if !aiInterpretation.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "sparkles").foregroundStyle(Theme.signal)
                    Text(aiInterpretation).font(.subheadline.weight(.semibold))
                }
                Text("\(aiHits.count) match\(aiHits.count == 1 ? "" : "es")").font(Theme.mono(11)).foregroundStyle(Theme.inkMuted)
                LazyVStack(spacing: 10) {
                    ForEach(aiHits) { hit in row(hit.book, reason: hit.reason) }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Ask in your own words").font(Theme.display(22))
                ForEach(["Books about public housing in American cities",
                         "The yellow MIT Press book about Las Vegas",
                         "Everything by Christopher Alexander",
                         "Novels set in New York on bookcase B"], id: \.self) { example in
                    Button {
                        query = example
                        Task { await askAI() }
                    } label: {
                        Text("“\(example)”").font(.callout).foregroundStyle(Theme.signal)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 10)
        }
    }

    /// Sends the request and the whole catalog to Claude. Books are listed in a stable order so
    /// the catalog part of the prompt is cached between questions.
    private func askAI() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        aiWorking = true
        aiError = nil
        defer { aiWorking = false }
        let ordered = books.sorted { $0.dateAdded == $1.dateAdded ? $0.title < $1.title : $0.dateAdded < $1.dateAdded }
        let lines: [String] = ordered.enumerated().map { pair -> String in
            let b: Book = pair.element
            let titleField: String = [b.title, b.subtitle].filter { !$0.isEmpty }.joined(separator: " : ")
            let imprintField: String = [b.edition, b.publisher].filter { !$0.isEmpty }.joined(separator: ", ")
            let caseName: String = b.shelf?.bookcase?.name ?? ""
            let fields: [String] = [String(pair.offset + 1), titleField,
                                    b.authorsText, b.year, b.lcCallNumber,
                                    b.subjects.joined(separator: "; "),
                                    imprintField,
                                    "\(b.address) (\(caseName))",
                                    b.graphicNotes, b.notes]
            return fields.joined(separator: " | ")
        }
        let catalog = lines.joined(separator: "\n")
        do {
            let result = try await CatalogSearchService().search(q, catalog: catalog)
            aiInterpretation = result.interpretation
            aiHits = result.results.compactMap { hit in
                ordered.indices.contains(hit.index - 1) ? AIHit(book: ordered[hit.index - 1], reason: hit.reason) : nil
            }
        } catch {
            aiError = error.localizedDescription
            aiInterpretation = ""
            aiHits = []
        }
    }

    private var controls: some View {
        HStack {
            Picker("Sort", selection: $sort) {
                ForEach(SortOrder.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            Button {
                withAnimation(.snappy) { layout = layout == .list ? .spines : .list }
            } label: {
                Image(systemName: layout == .list ? "books.vertical" : "list.bullet")
                    .font(.system(size: 17, weight: .bold))
                    .frame(width: 40, height: 32)
                    .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

struct AIHit: Identifiable {
    let book: Book
    let reason: String
    var id: PersistentIdentifier { book.persistentModelID }
}

private struct StatsStrip: View {
    let books: [Book]
    let bookcases: [Bookcase]

    var body: some View {
        let matched = books.filter { $0.catalogStatus == .matched }.count
        HStack(spacing: 10) {
            stat("\(books.count)", "books")
            stat("\(bookcases.count)", "cases")
            stat(books.isEmpty ? "–" : "\(Int(Double(matched) / Double(books.count) * 100))%", "LC matched")
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(Theme.display(34)).foregroundStyle(Theme.ink)
            SectionLabel(text: label)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct BookRow: View {
    let book: Book
    var query: String = ""

    var body: some View {
        HStack(spacing: 14) {
            SpineSwatch(colorHex: book.colorHex, accentHex: book.accentColorHex, title: book.shortTitle,
                        width: 18, height: 64, minFont: 3)
            VStack(alignment: .leading, spacing: 4) {
                Text(book.title.isEmpty ? "Unidentified spine" : book.title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                if !book.authorsText.isEmpty {
                    Text(book.authorsText).font(.subheadline).foregroundStyle(Theme.inkMuted).lineLimit(1)
                }
                HStack(spacing: 8) {
                    if !book.lcCallNumber.isEmpty {
                        Text(book.lcCallNumber).font(Theme.mono(11)).foregroundStyle(Theme.inkMuted)
                    } else {
                        StatusDot(status: book.catalogStatus)
                    }
                }
            }
            Spacer(minLength: 4)
            AddressBadge(address: book.address)
        }
        .padding(12)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
        .contentShape(Rectangle())
    }
}

struct StatusDot: View {
    let status: CatalogStatus
    private var info: (color: Color, text: String) {
        switch status {
        case .matched: return (.green, "LC record")
        case .partial: return (.yellow, "Partial record")
        case .notFound: return (.red, "No LC record")
        case .pending: return (.gray, "Not cataloged")
        }
    }
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(info.color).frame(width: 7, height: 7)
            Text(info.text).font(Theme.mono(11)).foregroundStyle(Theme.inkMuted)
        }
    }
}

/// Search results drawn as a row of spines, for browsing by eye.
private struct SpineWall: View {
    let books: [Book]
    @Environment(Router.self) private var router

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 30, maximum: 40), spacing: 4)], spacing: 10) {
            ForEach(books) { book in
                Button { router.find(book) } label: {
                    SpineSwatch(colorHex: book.colorHex, accentHex: book.accentColorHex,
                                title: book.shortTitle, author: book.authorSurname, width: 32, height: 150)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(Theme.wood.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct EmptyCatalog: View {
    let scan: () -> Void
    var body: some View {
        VStack(spacing: 22) {
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(Array(["#B23A2E", "#E8DCC0", "#1F3A5F", "#FF5A1F", "#2E2E2E", "#6B8F71"].enumerated()), id: \.offset) { i, c in
                    SpineSwatch(colorHex: c, accentHex: "#FFFFFF", width: 22 + CGFloat(i % 3) * 6, height: 90 + CGFloat((i * 37) % 40))
                }
            }
            Text("Your shelves, indexed.").font(Theme.display(34))
            Text("Photograph a shelf, or pan along it with video. Shelfmark reads every spine, finds the Library of Congress record, and remembers exactly where each book lives.")
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.inkMuted)
                .padding(.horizontal, 30)
            Button("Scan your first shelf", action: scan)
                .buttonStyle(SignalButtonStyle())
                .padding(.horizontal, 40)
        }
    }
}
