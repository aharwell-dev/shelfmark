import SwiftUI
import SwiftData

/// The visual finding aid: every bookcase in the collection drawn as an elevation,
/// with the sought-for book lit up and everything else dimmed. A second mode shows
/// the book in the actual shelf photograph.
struct FindingAidView: View {
    @Environment(Router.self) private var router
    @Query(sort: \Bookcase.sortOrder) private var bookcases: [Bookcase]
    @Query private var books: [Book]

    @State private var mode: Mode = .plan
    @State private var query = ""
    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    @State private var inspected: Book?

    enum Mode: String, CaseIterable, Identifiable { case plan = "Plan", photo = "Photo"; var id: String { rawValue } }

    private var target: Book? { router.highlighted }
    private let minZoom: CGFloat = 0.3
    private let maxZoom: CGFloat = 6
    private var effectiveZoom: CGFloat { clampZoom(zoom * pinch) }
    private func clampZoom(_ z: CGFloat) -> CGFloat { min(max(z, minZoom), maxZoom) }

    private var matches: [Book] {
        let terms = query.split(separator: " ").map(String.init)
        guard !terms.isEmpty else { return [] }
        return books.filter { b in terms.allSatisfy { b.searchBlob.localizedStandardContains($0) } }
            .sorted { $0.title < $1.title }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                if !matches.isEmpty && !query.isEmpty { resultsStrip }
                if let target { TargetCard(book: target) { router.highlighted = nil } }
                Picker("View", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 10)

                if bookcases.isEmpty {
                    ContentUnavailableView("No bookcases yet", systemImage: "books.vertical",
                                           description: Text("Scan a shelf to start building the finding aid."))
                } else if mode == .plan {
                    planView
                } else {
                    PhotoFinder(book: target)
                }
            }
            .background(Theme.ground)
            .navigationTitle("Finder")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $inspected) { book in
                NavigationStack { BookDetailView(book: book) }
                    .presentationDetents([.medium, .large])
            }
        }
    }

    // MARK: Search

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.inkMuted)
            TextField("Find a book…", text: $query)
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .onSubmit { if let first = matches.first { select(first) } }
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.inkMuted) }
            }
        }
        .padding(12)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var resultsStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(matches.prefix(25)) { b in
                    Button { select(b) } label: {
                        HStack(spacing: 8) {
                            SpineSwatch(colorHex: b.colorHex, accentHex: b.accentColorHex, title: b.shortTitle,
                                        width: 8, height: 34, minFont: 3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(b.title).font(.caption.weight(.bold)).lineLimit(1)
                                Text(b.address).font(Theme.mono(10)).foregroundStyle(Theme.signal)
                            }
                        }
                        .padding(8)
                        .frame(maxWidth: 200, alignment: .leading)
                        .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
        }
    }

    private func select(_ book: Book) {
        withAnimation(.spring(duration: 0.5)) { router.highlighted = book }
        query = ""
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    // MARK: Plan (elevation)

    private var planView: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView([.horizontal, .vertical], showsIndicators: false) {
                    HStack(alignment: .bottom, spacing: 26 * effectiveZoom) {
                        ForEach(bookcases) { bc in
                            BookcaseElevation(bookcase: bc, target: target, zoom: effectiveZoom) { inspected = $0 }
                                .id(bc.persistentModelID)
                        }
                    }
                    .padding(.horizontal, 30)
                    .padding(.top, 70)       // room for the location flag above the top shelf
                    .padding(.bottom, 30)
                }
                // Simultaneous, so a two-finger pinch zooms while one finger still scrolls.
                .simultaneousGesture(
                    MagnifyGesture()
                        .updating($pinch) { v, state, _ in state = v.magnification }
                        .onEnded { v in
                            zoom = clampZoom(zoom * v.magnification)
                            scrollToTarget(proxy)
                        })
                .overlay(alignment: .bottomTrailing) {
                    zoomControls(fit: fitZoom(width: geo.size.width), proxy: proxy)
                }
                .onAppear { scrollToTarget(proxy) }
                .onChange(of: router.highlighted) { _, _ in scrollToTarget(proxy) }
            }
        }
    }

    /// The zoom at which every bookcase fits across the screen.
    private func fitZoom(width: CGFloat) -> CGFloat {
        let n = CGFloat(max(bookcases.count, 1))
        let natural = n * (280 + 16) + (n - 1) * 26     // case widths and gaps at zoom 1
        return clampZoom((width - 60) / natural)
    }

    private func scrollToTarget(_ proxy: ScrollViewProxy) {
        guard let bc = target?.shelf?.bookcase else { return }
        withAnimation(.easeInOut(duration: 0.6)) { proxy.scrollTo(bc.persistentModelID, anchor: .center) }
    }

    private func zoomControls(fit: CGFloat, proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 0) {
            Button { withAnimation(.snappy) { zoom = clampZoom(zoom * 1.4) }; scrollToTarget(proxy) } label: {
                Image(systemName: "plus").frame(width: 44, height: 40)
            }
            Divider().frame(width: 44)
            Button { withAnimation(.snappy) { zoom = clampZoom(zoom / 1.4) }; scrollToTarget(proxy) } label: {
                Image(systemName: "minus").frame(width: 44, height: 40)
            }
            Divider().frame(width: 44)
            Button { withAnimation(.snappy) { zoom = fit } } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left").frame(width: 44, height: 40)
            }
            .accessibilityLabel("Fit all bookcases")
            Divider().frame(width: 44)
            Text("\(Int((effectiveZoom * 100).rounded()))%")
                .font(Theme.mono(10, weight: .bold))
                .foregroundStyle(Theme.inkMuted)
                .frame(width: 44, height: 26)
        }
        .font(.system(size: 15, weight: .bold))
        .foregroundStyle(Theme.ink)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding()
    }
}

// MARK: - Target card

private struct TargetCard: View {
    let book: Book
    let clear: () -> Void
    @Environment(Router.self) private var router

    var body: some View {
        HStack(spacing: 12) {
            SpineSwatch(colorHex: book.colorHex, accentHex: book.accentColorHex, title: book.shortTitle,
                        width: 14, height: 54, minFont: 3)
            VStack(alignment: .leading, spacing: 4) {
                Text(book.title.isEmpty ? "Unidentified spine" : book.title).font(.headline).lineLimit(1)
                Text(book.addressDescription).font(.caption).foregroundStyle(Theme.inkMuted).lineLimit(2)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                AddressBadge(address: book.address)
                if let shelf = book.shelf {
                    Button { router.reviewShelf = shelf } label: {
                        Text("Review shelf").font(.caption2.bold())
                    }
                }
            }
            Button(action: clear) { Image(systemName: "xmark").font(.caption.weight(.bold)).padding(6) }
                .foregroundStyle(Theme.inkMuted)
        }
        .padding(12)
        .background(Theme.signalSoft, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.signal.opacity(0.6)))
        .padding(.horizontal)
        .padding(.top, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

// MARK: - Bookcase elevation

/// One bookcase drawn front-on: carcass, shelves numbered from the top, and every
/// cataloged spine in proportion and in its captured color.
struct BookcaseElevation: View {
    let bookcase: Bookcase
    let target: Book?
    let zoom: CGFloat
    let onTap: (Book) -> Void
    @Environment(Router.self) private var router

    private var shelfHeight: CGFloat { 74 * zoom }
    private var caseWidth: CGFloat { 280 * zoom }
    private var containsTarget: Bool { target?.shelf?.bookcase == bookcase }
    private var dimmed: Bool { target != nil && !containsTarget }

    /// Points per unit of `Book.drawingWidth`, chosen so the fullest shelf fits the case.
    private var widthScale: CGFloat {
        let fullest = bookcase.shelves.map { $0.books.reduce(0) { $0 + $1.drawingWidth } }.max() ?? 0
        guard fullest > 0 else { return 1 }
        return min((caseWidth - 12) / fullest, 40 * zoom / 0.08)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            VStack(spacing: 0) {
                ForEach(bookcase.orderedShelves) { shelf in
                    shelfRow(shelf)
                }
            }
            .padding(.horizontal, 8 * zoom)
            .padding(.top, 8 * zoom)
            .background(Theme.wood.opacity(0.55))
            .overlay(Rectangle().stroke(Theme.wood, lineWidth: 6 * zoom))
            .frame(width: caseWidth + 16 * zoom)
        }
        .opacity(dimmed ? 0.35 : 1)
        .saturation(dimmed ? 0.2 : 1)
        .zIndex(containsTarget ? 1 : 0)
    }

    private var header: some View {
        Button { router.fullBookcase = bookcase } label: { headerLabel }
            .buttonStyle(.plain)
            .accessibilityHint("Shows the whole bookcase with spine titles")
    }

    private var headerLabel: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(bookcase.code)
                .font(Theme.display(34 * min(zoom, 1.4)))
                .foregroundStyle(containsTarget ? Theme.signal : Theme.ink)
            VStack(alignment: .leading, spacing: 0) {
                Text(bookcase.name).font(.subheadline.weight(.bold)).lineLimit(1)
                if !bookcase.room.isEmpty { Text(bookcase.room).font(.caption).foregroundStyle(Theme.inkMuted) }
            }
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.caption.weight(.bold)).foregroundStyle(Theme.inkMuted)
        }
    }

    private func shelfRow(_ shelf: Shelf) -> some View {
        let isTargetShelf = target?.shelf == shelf
        let books = shelf.orderedBooks
        let tallest = books.map { $0.boxY1 - $0.boxY0 }.max() ?? 1

        return ZStack(alignment: .bottomLeading) {
            // Back of the shelf bay.
            Rectangle().fill(Color.black.opacity(isTargetShelf ? 0.25 : 0.45))
            if shelf.holdsNonBooks {
                NonBookShelfFill(note: shelf.contentsNote)
            } else if books.isEmpty {
                Text("shelf \(shelf.number) · not scanned")
                    .font(Theme.mono(10 * min(zoom, 1.3)))
                    .foregroundStyle(Theme.inkMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(books) { book in
                    spine(book, tallest: tallest)
                }
            }
        }
        .frame(height: shelfHeight)
        .overlay(alignment: .leading) {
            // Shelf number tab on the left edge.
            Text("\(shelf.number)")
                .font(Theme.mono(10 * min(zoom, 1.5), weight: .black))
                .padding(.horizontal, 4).padding(.vertical, 2)
                .background(isTargetShelf ? Theme.signal : Theme.wood)
                .foregroundStyle(isTargetShelf ? .black : Theme.inkMuted)
                .offset(x: -(14 * zoom + 10))
        }
        .overlay(alignment: .bottom) {
            // The shelf board.
            Rectangle().fill(isTargetShelf ? Theme.signal : Theme.wood).frame(height: 5 * zoom).offset(y: 5 * zoom)
        }
        .padding(.bottom, 8 * zoom)
        .zIndex(isTargetShelf ? 1 : 0)
    }

    private func spine(_ book: Book, tallest: Double) -> some View {
        let isTarget = target == book
        let w = max(CGFloat(book.drawingWidth) * widthScale, 2)
        let relH = tallest > 0 ? (book.boxY1 - book.boxY0) / tallest : 1
        let h = shelfHeight * CGFloat(0.62 + 0.36 * relH)
        let othersDim = target != nil && !isTarget

        return SpineSwatch(colorHex: book.colorHex, accentHex: book.accentColorHex,
                           title: book.shortTitle, author: zoom > 1.8 ? book.authorSurname : "",
                           width: w, height: h, minFont: 3)
            .saturation(othersDim ? 0.15 : 1)
            .opacity(othersDim ? 0.45 : 1)
            .overlay { if isTarget { PulseRing() } }
            .overlay(alignment: .top) { if isTarget { LocationFlag(book: book).offset(y: -58) } }
            .scaleEffect(isTarget ? 1.12 : 1, anchor: .bottom)
            .shadow(color: isTarget ? Theme.signal.opacity(0.9) : .clear, radius: isTarget ? 10 : 0)
            .zIndex(isTarget ? 2 : 0)
            .contentShape(Rectangle())
            .onTapGesture { onTap(book) }
            .accessibilityLabel("\(book.title), \(book.address)")
    }
}

/// An animated outline that draws the eye to the target spine.
private struct PulseRing: View {
    @State private var on = false
    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .stroke(Theme.signal, lineWidth: 3)
            .padding(-4)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Theme.signal.opacity(on ? 0 : 0.8), lineWidth: 2)
                    .padding(on ? -14 : -4)
            )
            .onAppear { withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) { on = true } }
    }
}

/// The marker flag above the target: address plus a leader line down to the spine.
private struct LocationFlag: View {
    let book: Book
    var body: some View {
        VStack(spacing: 0) {
            Text(book.address)
                .font(Theme.mono(12, weight: .black))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Theme.signal, in: RoundedRectangle(cornerRadius: 5))
                .foregroundStyle(.black)
                .fixedSize()
            Rectangle().fill(Theme.signal).frame(width: 2, height: 22)
            Image(systemName: "arrowtriangle.down.fill").font(.system(size: 10)).foregroundStyle(Theme.signal).offset(y: -3)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Photo finder

/// The book shown in the actual shelf photograph: everything else darkened, the spine outlined.
struct PhotoFinder: View {
    let book: Book?
    @State private var pulse = false

    var body: some View {
        if let book, let photo = book.photo, let ui = UIImage(data: photo.imageData) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    let aspect = ui.size.width / max(ui.size.height, 1)
                    Image(uiImage: ui)
                        .resizable()
                        .aspectRatio(aspect, contentMode: .fit)
                        .frame(height: 420)
                        .overlay {
                            GeometryReader { geo in
                                let r = CGRect(x: book.box.minX * geo.size.width, y: book.box.minY * geo.size.height,
                                               width: book.box.width * geo.size.width, height: book.box.height * geo.size.height)
                                    .insetBy(dx: -4, dy: -4)
                                ZStack {
                                    // Dim everything except the spine.
                                    Path { p in
                                        p.addRect(CGRect(origin: .zero, size: geo.size))
                                        p.addRoundedRect(in: r, cornerSize: CGSize(width: 4, height: 4))
                                    }
                                    .fill(Color.black.opacity(0.72), style: FillStyle(eoFill: true))

                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(Theme.signal, lineWidth: 3)
                                        .frame(width: r.width, height: r.height)
                                        .position(x: r.midX, y: r.midY)
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Theme.signal.opacity(pulse ? 0 : 0.9), lineWidth: 2)
                                        .frame(width: r.width + (pulse ? 28 : 0), height: r.height + (pulse ? 28 : 0))
                                        .position(x: r.midX, y: r.midY)
                                    Color.clear.frame(width: 1, height: 1).position(x: r.midX, y: r.midY).id("target")
                                }
                            }
                        }
                }
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        withAnimation { proxy.scrollTo("target", anchor: .center) }
                    }
                    withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) { pulse = true }
                }
            }
            VStack(spacing: 6) {
                AddressBadge(address: book.address, large: true)
                Text(book.addressDescription).font(.footnote).foregroundStyle(Theme.inkMuted).multilineTextAlignment(.center)
                if let shelf = book.shelf, shelf.photos.count > 1 {
                    Text("Photo \(photo.order + 1) of \(shelf.photos.count) for this shelf")
                        .font(Theme.mono(10)).foregroundStyle(Theme.inkMuted)
                }
            }
            .padding()
            Spacer()
        } else {
            ContentUnavailableView(book == nil ? "Search for a book" : "No photo for this book",
                                   systemImage: "photo",
                                   description: Text(book == nil
                                                     ? "Find a book above to see it in its shelf photograph."
                                                     : "This book was added without a shelf photograph."))
        }
    }
}
