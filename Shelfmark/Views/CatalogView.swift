import SwiftUI
import SwiftData

/// The searchable catalog. Search covers title, author, subject, call number, ISBN, spine text and address.
struct CatalogView: View {
    @Query private var books: [Book]
    @Query(sort: \Bookcase.sortOrder) private var bookcases: [Bookcase]
    @Environment(Router.self) private var router
    @State private var query = ""
    @State private var sort: SortOrder = .callNumber
    @State private var layout: Layout = .list

    enum SortOrder: String, CaseIterable, Identifiable {
        case callNumber = "Call no.", title = "Title", author = "Author", location = "Location", recent = "Recent"
        var id: String { rawValue }
    }
    enum Layout { case list, spines }

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
                            StatsStrip(books: books, bookcases: bookcases)
                            controls
                            if layout == .list {
                                LazyVStack(spacing: 10) {
                                    ForEach(results) { book in
                                        NavigationLink(value: book) { BookRow(book: book, query: query) }
                                            .buttonStyle(.plain)
                                    }
                                }
                            } else {
                                SpineWall(books: results)
                            }
                            if results.isEmpty {
                                Text("No books match “\(query)”.")
                                    .foregroundStyle(Theme.inkMuted)
                                    .frame(maxWidth: .infinity)
                                    .padding(.top, 40)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.bottom, 30)
                    }
                }
            }
            .navigationTitle("Catalog")
            .navigationDestination(for: Book.self) { BookDetailView(book: $0) }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Title, author, subject, call number…")
            .onSubmit(of: .search) {
                // Submitting a search that matches exactly one book jumps straight to its location.
                if results.count == 1, let only = results.first { router.find(only) }
            }
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
            SpineSwatch(colorHex: book.colorHex, accentHex: book.accentColorHex, width: 18, height: 64)
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
                                title: book.title, width: 32, height: 150)
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
