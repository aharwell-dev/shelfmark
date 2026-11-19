import SwiftUI
import SwiftData

struct BookDetailView: View {
    @Bindable var book: Book
    @Environment(Router.self) private var router
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var lookingUp = false
    @State private var confirmDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                Button {
                    router.find(book)
                } label: {
                    Label("Show on shelf", systemImage: "scope")
                }
                .buttonStyle(SignalButtonStyle())

                if let photo = book.photo, let ui = UIImage(data: photo.imageData) {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(text: "As photographed")
                        SpineCrop(image: ui, box: book.box)
                    }
                }

                CatalogCard(book: book)

                if !book.spineText.isEmpty || !book.graphicNotes.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(text: "Read from the spine")
                        if !book.spineText.isEmpty { Text("“\(book.spineText)”").font(.callout.italic()) }
                        if !book.graphicNotes.isEmpty { Text(book.graphicNotes).font(.callout).foregroundStyle(Theme.inkMuted) }
                        Text("Identification confidence \(Int(book.confidence * 100))%")
                            .font(Theme.mono(11)).foregroundStyle(Theme.inkMuted)
                    }
                }

                HStack {
                    Button {
                        Task { await relookup() }
                    } label: {
                        Label(lookingUp ? "Searching…" : "Re-run LC lookup", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(SignalButtonStyle(filled: false))
                    .disabled(lookingUp || book.title.isEmpty)
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("Remove", systemImage: "trash")
                    }
                    .buttonStyle(SignalButtonStyle(filled: false))
                }
            }
            .padding()
        }
        .background(Theme.ground)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { Button("Edit") { editing = true } }
        .sheet(isPresented: $editing) { BookEditor(book: book) }
        .confirmationDialog("Remove this book from the catalog?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                let shelf = book.shelf
                if router.highlighted == book { router.highlighted = nil }
                context.delete(book)
                try? context.save()
                shelf?.renumberBooks()
                try? context.save()
                dismiss()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            SpineSwatch(colorHex: book.colorHex, accentHex: book.accentColorHex, title: book.title, width: 44, height: 180)
            VStack(alignment: .leading, spacing: 8) {
                Text(book.title.isEmpty ? "Unidentified spine" : book.title)
                    .font(Theme.display(30))
                    .fixedSize(horizontal: false, vertical: true)
                if !book.authorsText.isEmpty {
                    Text(book.authorsText).font(.title3.weight(.medium)).foregroundStyle(Theme.inkMuted)
                }
                Spacer(minLength: 6)
                AddressBadge(address: book.address, large: true)
                Text(book.addressDescription).font(.footnote).foregroundStyle(Theme.inkMuted)
            }
        }
    }

    private func relookup() async {
        lookingUp = true
        defer { lookingUp = false }
        let authors = book.authorsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if let record = await CatalogService().lookup(title: book.title, authors: authors) {
            apply(record, to: book)
        } else {
            book.catalogStatus = .notFound
        }
        try? context.save()
    }
}

/// A library catalog card: the LC call number set large, with the bibliographic record beneath.
private struct CatalogCard: View {
    let book: Book

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionLabel(text: "Library of Congress")
                Spacer()
                StatusDot(status: book.catalogStatus)
            }
            Text(book.lcCallNumber.isEmpty ? "No call number" : formattedCallNumber)
                .font(Theme.mono(24, weight: .bold))
                .foregroundStyle(book.lcCallNumber.isEmpty ? Theme.inkMuted : Theme.signal)
            Divider().overlay(Theme.line)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                row("Publisher", book.publisher)
                row("Date", book.year)
                row("ISBN", book.isbn)
                row("LCCN", book.lccn)
                row("Source", book.catalogSource)
            }
            if !book.subjects.isEmpty {
                SectionLabel(text: "Subjects")
                FlowLayout(spacing: 6) {
                    ForEach(book.subjects, id: \.self) { s in
                        Text(s).font(.caption)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(Theme.panelRaised, in: Capsule())
                    }
                }
            }
        }
        .padding(16)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line))
    }

    /// Stacks the call number the way it's printed on a spine label.
    private var formattedCallNumber: String {
        book.lcCallNumber.replacingOccurrences(of: " .", with: "\n.").replacingOccurrences(of: " ", with: "\n")
    }

    @ViewBuilder private func row(_ label: String, _ value: String) -> some View {
        if !value.isEmpty {
            GridRow {
                Text(label.uppercased()).font(Theme.mono(10, weight: .bold)).foregroundStyle(Theme.inkMuted)
                Text(value).font(.callout).textSelection(.enabled)
            }
        }
    }
}

/// Shows the spine cut out of the original shelf photo, rotated to read horizontally.
private struct SpineCrop: View {
    let image: UIImage
    let box: CGRect

    var body: some View {
        if let cg = image.cgImage,
           let crop = ImageUtils.crop(cg, normalized: box.insetBy(dx: -box.width * 0.15, dy: -0.01)) {
            // Orientation .left rotates the vertical spine so its lettering reads left to right.
            Image(uiImage: UIImage(cgImage: crop, scale: 1, orientation: .left))
                .resizable()
                .scaledToFit()
                .frame(height: 70)
                .frame(maxWidth: .infinity)
                .clipped()
                .padding(.vertical, 6)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

struct BookEditor: View {
    @Bindable var book: Book
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Book") {
                    TextField("Title", text: $book.title)
                    TextField("Authors", text: $book.authorsText)
                    TextField("Publisher", text: $book.publisher)
                    TextField("Year", text: $book.year)
                }
                Section("Catalog") {
                    TextField("LC call number", text: $book.lcCallNumber).font(Theme.mono(15))
                    TextField("ISBN", text: $book.isbn)
                    TextField("LCCN", text: $book.lccn)
                    TextField("Subjects (separate with |)", text: $book.subjectsText, axis: .vertical)
                }
                Section("Notes") {
                    TextField("Condition, provenance, loans…", text: $book.notes, axis: .vertical)
                }
            }
            .navigationTitle("Edit book")
            .toolbar {
                Button("Done") {
                    book.lcClass = LCCallNumber.classLetters(book.lcCallNumber)
                    if !book.lcCallNumber.isEmpty { book.catalogStatus = .matched }
                    dismiss()
                }
            }
        }
    }
}

/// Simple wrapping layout for subject tags.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing
            rowH = max(rowH, s.height)
            maxX = max(maxX, x)
        }
        return CGSize(width: min(maxX, width), height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}
