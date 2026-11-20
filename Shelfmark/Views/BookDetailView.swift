import SwiftUI
import SwiftData

struct BookDetailView: View {
    @Bindable var book: Book
    @Environment(Router.self) private var router
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var identifying = false
    @State private var lookingUp: String?
    @State private var confirmDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                if book.isUnidentified || book.catalogStatus == .notFound {
                    identifyPrompt
                }

                HStack(spacing: 10) {
                    Button { router.find(book) } label: { Label("Show on shelf", systemImage: "scope") }
                        .buttonStyle(SignalButtonStyle())
                    if let shelf = book.shelf {
                        Button { router.reviewShelf = shelf } label: { Label("Review shelf", systemImage: "checkmark.circle") }
                            .buttonStyle(SignalButtonStyle(filled: false))
                    }
                }

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

                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        Button { Task { await relookup(deep: false) } } label: {
                            Label(lookingUp == "fast" ? "Searching…" : "Look up again", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(SignalButtonStyle(filled: false))
                        Button { Task { await relookup(deep: true) } } label: {
                            Label(lookingUp == "deep" ? "Researching…" : "Research online", systemImage: "globe")
                        }
                        .buttonStyle(SignalButtonStyle(filled: false))
                    }
                    .disabled(lookingUp != nil || book.title.isEmpty)
                    if lookingUp == "deep" {
                        Text("Claude is searching library catalogs and publisher records. This can take a minute.")
                            .font(.caption).foregroundStyle(Theme.inkMuted)
                    }
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("Delete from catalog", systemImage: "trash")
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
        .sheet(isPresented: $identifying) {
            IdentifyBookView(initialTitle: book.title, initialAuthors: book.authorsText,
                             spineText: book.spineText, designNotes: book.graphicNotes) { record, clues in
                applyIdentification(record, clues, to: book)
                try? context.save()
            }
        }
        .confirmationDialog("Delete this book from the catalog?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                deleteBook(book, context: context, router: router)
                dismiss()
            }
        } message: {
            Text("The rest of the shelf is renumbered so addresses stay continuous.")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            SpineSwatch(colorHex: book.colorHex, accentHex: book.accentColorHex,
                        title: book.shortTitle, author: book.authorSurname, width: 44, height: 190)
            VStack(alignment: .leading, spacing: 8) {
                Text(book.title.isEmpty ? "Unidentified spine" : book.title)
                    .font(Theme.display(30))
                    .fixedSize(horizontal: false, vertical: true)
                if !book.subtitle.isEmpty {
                    Text(book.subtitle).font(.callout).foregroundStyle(Theme.inkMuted)
                }
                if !book.authorsText.isEmpty {
                    Text(book.authorsText).font(.title3.weight(.medium)).foregroundStyle(Theme.inkMuted)
                }
                if book.verified {
                    Label("Confirmed", systemImage: "checkmark.seal.fill").font(.caption.bold()).foregroundStyle(.green)
                }
                Spacer(minLength: 6)
                AddressBadge(address: book.address, large: true)
                Text(book.addressDescription).font(.footnote).foregroundStyle(Theme.inkMuted)
            }
        }
    }

    private var identifyPrompt: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(book.title.isEmpty ? "This spine wasn't identified" : "No catalog record found",
                  systemImage: "questionmark.circle.fill")
                .font(.headline).foregroundStyle(.yellow)
            Text("Photograph the cover, title page or copyright page, or type the title and author.")
                .font(.callout).foregroundStyle(Theme.inkMuted)
            Button { identifying = true } label: { Label("Identify this book", systemImage: "camera.viewfinder") }
                .buttonStyle(SignalButtonStyle())
        }
        .padding(14)
        .background(Color.yellow.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
    }

    private func relookup(deep: Bool) async {
        lookingUp = deep ? "deep" : "fast"
        defer { lookingUp = nil }
        let clues = BookClues(title: book.title,
                              authors: book.authorsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) },
                              publisher: book.publisher, spineText: book.spineText,
                              designNotes: book.graphicNotes, isbn: book.isbn)
        if let record = await CatalogService().lookup(clues, deep: deep) {
            apply(record, to: book)
        } else if book.lcCallNumber.isEmpty {
            book.catalogStatus = .notFound
        }
        try? context.save()
    }
}

/// The record laid out like a Library of Congress catalog card: call number at left, main
/// entry, title and statement of responsibility, edition, imprint, standard numbers, then
/// numbered subject headings, each of which opens every book in the collection under it.
private struct CatalogCard: View {
    let book: Book

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionLabel(text: "Catalog record")
                Spacer()
                StatusDot(status: book.catalogStatus)
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 0) {
                    if book.lcCallNumber.isEmpty {
                        Text("—").font(Theme.mono(20, weight: .bold)).foregroundStyle(Theme.inkMuted)
                    } else {
                        ForEach(LCCallNumber.labelLines(book.lcCallNumber), id: \.self) { line in
                            Text(line).font(Theme.mono(18, weight: .bold)).foregroundStyle(Theme.signal)
                        }
                    }
                }
                .frame(minWidth: 70, alignment: .leading)

                VStack(alignment: .leading, spacing: 6) {
                    if !book.authorHeading.isEmpty { Text(book.authorHeading).font(.callout.weight(.semibold)) }
                    Text(titleStatement).font(.callout).fixedSize(horizontal: false, vertical: true)
                    if !imprint.isEmpty { Text(imprint).font(.callout) }
                }
                .textSelection(.enabled)
            }
            if !book.callNumberSource.isEmpty {
                Text("Call number: \(book.callNumberSource)")
                    .font(.caption).foregroundStyle(book.callNumberSource.contains("Proposed") ? .yellow : Theme.inkMuted)
            }
            Divider().overlay(Theme.line)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                row("ISBN", book.isbn)
                row("LCCN", book.lccn)
                row("Sources", book.catalogSource)
            }
            if let url = URL(string: book.catalogURL), !book.catalogURL.isEmpty {
                Link(destination: url) { Label("View source record", systemImage: "arrow.up.right.square").font(.caption) }
            }
            if !book.subjects.isEmpty {
                SectionLabel(text: "Subjects")
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(book.subjects.enumerated()), id: \.offset) { i, s in
                        NavigationLink {
                            SubjectBooksView(heading: s)
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("\(i + 1).").font(Theme.mono(12)).foregroundStyle(Theme.inkMuted)
                                Text(s).font(.callout).foregroundStyle(Theme.signal).multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Theme.inkMuted)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(16)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line))
    }

    /// "Title : subtitle / Authors." in ISBD order.
    private var titleStatement: String {
        var t = book.title.isEmpty ? "[Untitled]" : book.title
        if !book.subtitle.isEmpty { t += " : \(book.subtitle)" }
        if !book.authorsText.isEmpty { t += " / \(book.authorsText)" }
        return t + "."
    }

    /// "1st ed. — New York : Random House, 1961."
    private var imprint: String {
        var parts: [String] = []
        if !book.edition.isEmpty { parts.append(book.edition) }
        var pub = ""
        if !book.publicationPlace.isEmpty { pub += book.publicationPlace + " : " }
        pub += book.publisher
        if !book.year.isEmpty { pub += pub.isEmpty ? book.year : ", \(book.year)" }
        if !pub.isEmpty { parts.append(pub + ".") }
        return parts.joined(separator: " — ")
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
                    TextField("Subtitle", text: $book.subtitle)
                    TextField("Authors (display form)", text: $book.authorsText)
                    TextField("Main entry, e.g. Jacobs, Jane, 1916-2006", text: $book.authorHeading)
                }
                Section("Edition and imprint") {
                    TextField("Edition, e.g. 1st ed.", text: $book.edition)
                    TextField("Place of publication", text: $book.publicationPlace)
                    TextField("Publisher", text: $book.publisher)
                    TextField("Year", text: $book.year)
                }
                Section("Catalog") {
                    TextField("LC call number", text: $book.lcCallNumber).font(Theme.mono(15))
                        .textInputAutocapitalization(.characters)
                    TextField("ISBN", text: $book.isbn)
                    TextField("LCCN", text: $book.lccn)
                    TextField("Subjects (separate with |, subdivisions with --)", text: $book.subjectsText, axis: .vertical)
                }
                Section("Notes") {
                    TextField("Condition, provenance, loans…", text: $book.notes, axis: .vertical)
                }
            }
            .navigationTitle("Edit book")
            .toolbar {
                Button("Done") {
                    // Keep hand-entered data in the same LC form as everything else.
                    let original = book.lcCallNumber
                    book.lcCallNumber = LCCallNumber.normalize(book.lcCallNumber)
                    book.lcClass = LCCallNumber.classLetters(book.lcCallNumber)
                    book.subjectsText = LCSH.normalize(book.subjectsText.split(separator: "|").map(String.init))
                        .joined(separator: " | ")
                    if !original.isEmpty && book.callNumberSource.isEmpty { book.callNumberSource = "Entered by hand" }
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
