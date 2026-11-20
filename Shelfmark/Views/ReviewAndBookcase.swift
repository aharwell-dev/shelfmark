import SwiftUI
import SwiftData

// MARK: - Review mode

/// Steps across a shelf one book at a time, left to right, showing each spine as photographed
/// beside its catalog record. One tap confirms a book and moves on.
struct ReviewModeView: View {
    let shelf: Shelf
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(Router.self) private var router
    @State private var index = 0
    @State private var editing: Book?
    @State private var identifying: Book?
    @State private var confirmDelete = false
    @State private var dragOffset: CGFloat = 0

    private var books: [Book] { shelf.orderedBooks }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if books.isEmpty {
                    ContentUnavailableView("No books on this shelf", systemImage: "books.vertical")
                } else if allVerified && index >= books.count {
                    finished
                } else {
                    let book = books[min(index, books.count - 1)]
                    header
                    ShelfStrip(books: books, current: min(index, books.count - 1)) { index = $0 }
                        .frame(height: 46)
                        .padding(.horizontal)
                    ScrollView {
                        VStack(spacing: 16) {
                            SpineInPhoto(book: book).frame(height: 230)
                            ReviewCard(book: book)
                        }
                        .padding()
                        .offset(x: dragOffset)
                    }
                    .gesture(DragGesture(minimumDistance: 30)
                        .onChanged { dragOffset = $0.translation.width / 3 }
                        .onEnded { v in
                            withAnimation(.snappy) {
                                if v.translation.width < -80 { step(1) } else if v.translation.width > 80 { step(-1) }
                                dragOffset = 0
                            }
                        })
                    actions(book)
                }
            }
            .background(Theme.ground)
            .navigationTitle("Review \(shelf.label)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $editing) { BookEditor(book: $0) }
            .sheet(item: $identifying) { book in
                IdentifyBookView(initialTitle: book.title, initialAuthors: book.authorsText,
                                 spineText: book.spineText, designNotes: book.graphicNotes) { record, clues in
                    applyIdentification(record, clues, to: book)
                    try? context.save()
                }
            }
        }
        .onAppear {
            // Start at the first book not yet confirmed.
            index = books.firstIndex { !$0.verified } ?? 0
        }
    }

    private var allVerified: Bool { !books.isEmpty && books.allSatisfy(\.verified) }

    private var header: some View {
        let verified = books.filter(\.verified).count
        return VStack(spacing: 6) {
            HStack {
                Text("Book \(min(index, books.count - 1) + 1) of \(books.count)").font(Theme.display(22))
                Spacer()
                Text("\(verified) confirmed").font(Theme.mono(12, weight: .bold)).foregroundStyle(Theme.signal)
            }
            ProgressBar(value: Double(verified) / Double(max(books.count, 1)), height: 5)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private func actions(_ book: Book) -> some View {
        VStack(spacing: 10) {
            Button {
                book.verified = true
                try? context.save()
                withAnimation(.snappy) { advanceToNextUnverified() }
            } label: {
                Label(book.isUnidentified ? "Confirm as is" : "Correct", systemImage: "checkmark")
            }
            .buttonStyle(SignalButtonStyle())

            HStack(spacing: 10) {
                Button { withAnimation(.snappy) { step(-1) } } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(SignalButtonStyle(filled: false)).frame(width: 56)
                Button { identifying = book } label: { Label("Identify", systemImage: "camera.viewfinder") }
                    .buttonStyle(SignalButtonStyle(filled: false))
                Button { editing = book } label: { Label("Edit", systemImage: "pencil") }
                    .buttonStyle(SignalButtonStyle(filled: false))
                Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                    .buttonStyle(SignalButtonStyle(filled: false)).frame(width: 56)
                Button { withAnimation(.snappy) { step(1) } } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(SignalButtonStyle(filled: false)).frame(width: 56)
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .confirmationDialog("Delete “\(book.title.isEmpty ? "this spine" : book.title)” from the catalog?",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                deleteBook(book, context: context, router: router)
                index = min(index, max(books.count - 1, 0))
            }
        }
    }

    private var finished: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 56)).foregroundStyle(Theme.signal)
            Text("Shelf \(shelf.label) confirmed").font(Theme.display(30))
            Text("All \(books.count) books have been checked.").foregroundStyle(Theme.inkMuted)
            Button("Review again from the start") { index = 0 }.buttonStyle(SignalButtonStyle(filled: false)).padding(.horizontal, 60)
            Button("Done") { dismiss() }.buttonStyle(SignalButtonStyle()).padding(.horizontal, 60)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func step(_ delta: Int) {
        index = min(max(index + delta, 0), books.count - 1)
    }

    private func advanceToNextUnverified() {
        if let next = books.indices.first(where: { $0 > index && !books[$0].verified }) { index = next }
        else if let earlier = books.firstIndex(where: { !$0.verified }) { index = earlier }
        else { index = books.count }   // all confirmed
    }
}

/// Applies the result of the identify flow to a saved book.
@MainActor
func applyIdentification(_ record: CatalogRecord?, _ clues: BookClues, to book: Book) {
    if let record {
        apply(record, to: book)
    } else {
        if !clues.title.isEmpty { book.title = clues.title }
        if !clues.authors.isEmpty { book.authorsText = clues.authors.joined(separator: ", ") }
        if !clues.publisher.isEmpty { book.publisher = clues.publisher }
        if !clues.isbn.isEmpty { book.isbn = clues.isbn }
        book.catalogStatus = book.title.isEmpty ? .pending : .notFound
    }
}

/// The book's spine cut from the shelf photograph, with its neighbours dimmed for context.
struct SpineInPhoto: View {
    let book: Book

    var body: some View {
        if let photo = book.photo, let ui = UIImage(data: photo.imageData), let cg = ui.cgImage {
            let box = book.box
            // Show the spine with about three spine-widths of context on each side.
            let pad = max(box.width * 3, 0.04)
            let window = CGRect(x: max(box.minX - pad, 0), y: 0,
                                width: min(box.width + pad * 2, 1 - max(box.minX - pad, 0)), height: 1)
            if let crop = ImageUtils.crop(cg, normalized: window) {
                GeometryReader { geo in
                    let img = UIImage(cgImage: crop)
                    let aspect = img.size.width / max(img.size.height, 1)
                    let size = fit(aspect: aspect, in: geo.size)
                    let hx = (box.minX - window.minX) / window.width * size.width
                    let hw = box.width / window.width * size.width
                    let hy = box.minY * size.height, hh = box.height * size.height
                    ZStack(alignment: .topLeading) {
                        Image(uiImage: img).resizable().frame(width: size.width, height: size.height)
                        Path { p in
                            p.addRect(CGRect(origin: .zero, size: size))
                            p.addRect(CGRect(x: hx, y: hy, width: hw, height: hh))
                        }
                        .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                        RoundedRectangle(cornerRadius: 3).stroke(Theme.signal, lineWidth: 3)
                            .frame(width: hw + 6, height: hh + 6)
                            .offset(x: hx - 3, y: hy - 3)
                    }
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else {
            SpineSwatch(colorHex: book.colorHex, accentHex: book.accentColorHex,
                        title: book.shortTitle, author: book.authorSurname, width: 50, height: 220)
                .frame(maxWidth: .infinity)
        }
    }

    private func fit(aspect: CGFloat, in s: CGSize) -> CGSize {
        let h = min(s.height, s.width / max(aspect, 0.01))
        return CGSize(width: h * aspect, height: h)
    }
}

/// The catalog record laid out for quick checking.
private struct ReviewCard: View {
    let book: Book

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                AddressBadge(address: book.address)
                Spacer()
                if book.verified {
                    Label("Confirmed", systemImage: "checkmark.seal.fill").font(.caption.bold()).foregroundStyle(.green)
                } else {
                    StatusDot(status: book.catalogStatus)
                }
            }
            Text(book.title.isEmpty ? "Unidentified spine" : book.title).font(Theme.display(26))
                .foregroundStyle(book.title.isEmpty ? Theme.inkMuted : Theme.ink)
            if !book.subtitle.isEmpty { Text(book.subtitle).font(.callout) }
            if !book.authorsText.isEmpty { Text(book.authorsText).font(.title3).foregroundStyle(Theme.inkMuted) }
            let imprint = [book.edition, book.publisher, book.year].filter { !$0.isEmpty }.joined(separator: " · ")
            if !imprint.isEmpty { Text(imprint).font(.subheadline) }
            if !book.lcCallNumber.isEmpty {
                HStack {
                    Text(book.lcCallNumber).font(Theme.mono(18, weight: .bold)).foregroundStyle(Theme.signal)
                    Spacer()
                    Text(book.callNumberSource).font(.caption2).foregroundStyle(Theme.inkMuted)
                }
            }
            if !book.spineText.isEmpty {
                Text("Spine: “\(book.spineText)”").font(.caption.italic()).foregroundStyle(Theme.inkMuted)
            }
            if book.isUnidentified {
                Label("Not identified. Tap Identify to photograph the cover or type the title.", systemImage: "questionmark.circle")
                    .font(.footnote).foregroundStyle(.yellow)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16))
    }
}

/// The whole shelf as a row of colored spines with the current book marked.
private struct ShelfStrip: View {
    let books: [Book]
    let current: Int
    let select: (Int) -> Void

    var body: some View {
        GeometryReader { geo in
            let total = max(books.reduce(0) { $0 + $1.drawingWidth }, 0.001)
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(Array(books.enumerated()), id: \.element.id) { i, b in
                    Rectangle()
                        .fill(Color(hex: b.colorHex, fallback: .gray))
                        .frame(width: max(geo.size.width * b.drawingWidth / total, 2),
                               height: geo.size.height * (i == current ? 1 : 0.75))
                        .overlay(alignment: .top) {
                            if b.verified { Circle().fill(.green).frame(width: 4, height: 4).padding(.top, 2) }
                        }
                        .overlay { if i == current { Rectangle().stroke(Theme.signal, lineWidth: 2) } }
                        .opacity(i == current ? 1 : 0.6)
                        .onTapGesture { select(i) }
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }
}

// MARK: - Full illustrated bookcase

/// A bookcase drawn full screen, every spine in its measured color with an abbreviated title
/// and the author's surname. Pinch or use the buttons to zoom; tap a spine for its record.
struct BookcaseFullView: View {
    let bookcase: Bookcase
    @Environment(\.dismiss) private var dismiss
    @Environment(Router.self) private var router
    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    @State private var inspected: Book?
    @State private var editingContents: Shelf?

    private var z: CGFloat { min(max(zoom * pinch, 1), 4) }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let caseWidth = (geo.size.width - 60) * z
                ScrollView([.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(bookcase.orderedShelves) { shelf in
                            shelfRow(shelf, width: caseWidth)
                        }
                    }
                    .padding(10)
                    .background(Theme.wood.opacity(0.55))
                    .overlay(Rectangle().stroke(Theme.wood, lineWidth: 8))
                    .padding(.leading, 34)
                    .padding(.trailing, 16)
                    .padding(.vertical, 20)
                }
                .gesture(MagnifyGesture().updating($pinch) { v, s, _ in s = v.magnification }
                    .onEnded { v in zoom = min(max(zoom * v.magnification, 1), 4) })
            }
            .background(Theme.ground)
            .navigationTitle("\(bookcase.code) · \(bookcase.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { withAnimation { zoom = max(zoom / 1.4, 1) } } label: { Image(systemName: "minus.magnifyingglass") }
                    Spacer()
                    Text("\(bookcase.bookCount) books").font(Theme.mono(12)).foregroundStyle(Theme.inkMuted)
                    Spacer()
                    Button { withAnimation { zoom = min(zoom * 1.4, 4) } } label: { Image(systemName: "plus.magnifyingglass") }
                }
            }
            .sheet(item: $inspected) { book in
                NavigationStack { BookDetailView(book: book) }.presentationDetents([.medium, .large])
            }
            .sheet(item: $editingContents) { ShelfContentsEditor(shelf: $0) }
        }
    }

    private func shelfRow(_ shelf: Shelf, width: CGFloat) -> some View {
        let books = shelf.orderedBooks
        let total = max(books.reduce(0) { $0 + $1.drawingWidth }, 0.001)
        // Scale so a full shelf fills the case; keep a sparse shelf's books at a natural width.
        let scale = min(width / total, 60 * z / 0.08)
        let shelfHeight = 170 * z
        let tallest = books.map { $0.boxY1 - $0.boxY0 }.max() ?? 1

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("SHELF \(shelf.number)").font(Theme.mono(10, weight: .black)).foregroundStyle(Theme.inkMuted)
                if !books.isEmpty {
                    Text("\(books.count) books · \(books.filter(\.verified).count) confirmed")
                        .font(Theme.mono(10)).foregroundStyle(Theme.inkMuted)
                }
                Spacer()
                Menu {
                    if !books.isEmpty {
                        Button { dismiss(); router.reviewShelf = shelf } label: { Label("Review one by one", systemImage: "checkmark.circle") }
                    }
                    Button { editingContents = shelf } label: { Label("Shelf holds something else…", systemImage: "square.dashed") }
                } label: {
                    Image(systemName: "ellipsis.circle").foregroundStyle(Theme.inkMuted)
                }
            }
            ZStack(alignment: .bottomLeading) {
                Rectangle().fill(Color.black.opacity(0.45))
                if shelf.holdsNonBooks {
                    NonBookShelfFill(note: shelf.contentsNote)
                } else if books.isEmpty {
                    Text("not scanned").font(Theme.mono(11)).foregroundStyle(Theme.inkMuted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(books) { b in
                        let relH = tallest > 0 ? (b.boxY1 - b.boxY0) / tallest : 1
                        SpineSwatch(colorHex: b.colorHex, accentHex: b.accentColorHex,
                                    title: b.shortTitle, author: b.authorSurname,
                                    width: max(CGFloat(b.drawingWidth) * scale, 3),
                                    height: shelfHeight * CGFloat(0.68 + 0.3 * relH))
                            .overlay(alignment: .top) {
                                if b.verified { Circle().fill(.green).frame(width: 5, height: 5).padding(.top, 3) }
                            }
                            .onTapGesture { inspected = b }
                    }
                }
            }
            .frame(width: width, height: shelfHeight)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.wood).frame(height: 6).offset(y: 6) }
            .padding(.bottom, 14)
        }
    }
}

/// Hatched fill with a label, for a shelf holding something other than books.
struct NonBookShelfFill: View {
    let note: String
    var body: some View {
        ZStack {
            Canvas { ctx, size in
                var p = Path()
                var x: CGFloat = -size.height
                while x < size.width {
                    p.move(to: CGPoint(x: x, y: size.height))
                    p.addLine(to: CGPoint(x: x + size.height, y: 0))
                    x += 10
                }
                ctx.stroke(p, with: .color(.white.opacity(0.08)), lineWidth: 1)
            }
            Text(note.uppercased())
                .font(Theme.mono(11, weight: .bold))
                .foregroundStyle(Theme.inkMuted)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Theme.ground.opacity(0.7), in: Capsule())
        }
    }
}

// MARK: - Shelf contents

/// Marks a shelf as holding something other than books, or back to books.
struct ShelfContentsEditor: View {
    let shelf: Shelf
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(Router.self) private var router
    @State private var note = ""
    @State private var removeBooks = true

    private let suggestions = ["Empty", "Records", "Magazines", "Photographs", "Ceramics", "Objects",
                               "Boxes and files", "Plants", "Art", "Games"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What's on shelf \(shelf.label)?", text: $note)
                    FlowLayout(spacing: 6) {
                        ForEach(suggestions, id: \.self) { s in
                            Button(s) { note = s }
                                .font(.caption)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(note == s ? Theme.signal : Theme.panelRaised, in: Capsule())
                                .foregroundStyle(note == s ? Color.black : Theme.ink)
                                .buttonStyle(.plain)
                        }
                    }
                } footer: {
                    Text("The shelf appears in the finding aid with this description instead of books.")
                }
                if !shelf.books.isEmpty {
                    Section {
                        Toggle("Remove the \(shelf.books.count) cataloged books from this shelf", isOn: $removeBooks)
                    }
                }
                if shelf.holdsNonBooks {
                    Section {
                        Button("This shelf holds books again") {
                            shelf.contentsNote = ""
                            try? context.save()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Shelf \(shelf.label)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        shelf.contentsNote = note.trimmingCharacters(in: .whitespaces)
                        if removeBooks {
                            for b in shelf.books {
                                if router.highlighted == b { router.highlighted = nil }
                                context.delete(b)
                            }
                            for p in shelf.photos { context.delete(p) }
                        }
                        shelf.lastScanned = .now
                        try? context.save()
                        dismiss()
                    }
                    .disabled(note.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { note = shelf.contentsNote }
        }
    }
}
