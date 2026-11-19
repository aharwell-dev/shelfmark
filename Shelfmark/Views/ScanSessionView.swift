import SwiftUI
import SwiftData

/// Runs the scan pipeline, then lets the user review and correct what was found before saving.
struct ScanSessionView: View {
    let input: ScanInput
    let shelf: Shelf
    let mode: SaveMode
    let onClose: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(Router.self) private var router
    @State private var pipeline = ScanPipeline()
    @State private var selected: DraftBook.ID?
    @State private var editing: EditTarget?

    struct EditTarget: Identifiable { let segment: Int; let book: Int; var id: String { "\(segment)-\(book)" } }

    var body: some View {
        NavigationStack {
            Group {
                switch pipeline.stage {
                case .review: review
                case .failed(let message): failure(message)
                default: ScanProgress(pipeline: pipeline)
                }
            }
            .background(Theme.ground)
            .navigationTitle("Shelf \(shelf.label)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onClose) }
            }
        }
        .task { await pipeline.run(input) }
        .sheet(item: $editing) { target in
            DraftEditor(book: $pipeline.segments[target.segment].books[target.book])
        }
    }

    // MARK: Review

    private var review: some View {
        let included = pipeline.allBooks.filter(\.include).count
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(pipeline.segments.enumerated()), id: \.element.id) { sIndex, segment in
                        AnnotatedShelfPhoto(segment: segment, selected: $selected, numberOffset: offset(before: sIndex))
                    }
                    HStack {
                        SectionLabel(text: "\(pipeline.allBooks.count) spines found · left to right")
                        Spacer()
                        Text("tap to edit").font(Theme.mono(10)).foregroundStyle(Theme.inkMuted)
                    }
                    ForEach(Array(pipeline.segments.enumerated()), id: \.element.id) { sIndex, segment in
                        ForEach(Array(segment.books.enumerated()), id: \.element.id) { bIndex, draft in
                            DraftRow(number: offset(before: sIndex) + bIndex + 1, draft: draft,
                                     isSelected: selected == draft.id,
                                     toggle: { pipeline.segments[sIndex].books[bIndex].include.toggle() })
                                .onTapGesture {
                                    selected = draft.id
                                    editing = EditTarget(segment: sIndex, book: bIndex)
                                }
                        }
                    }
                }
                .padding()
            }
            VStack(spacing: 6) {
                Button {
                    if mode == .replace, router.highlighted?.shelf == shelf { router.highlighted = nil }
                    pipeline.save(to: shelf, mode: mode, context: context)
                    onClose()
                } label: {
                    Text("Save \(included) books to \(shelf.label)")
                }
                .buttonStyle(SignalButtonStyle())
                .disabled(included == 0)
                Text(mode == .replace ? "Replaces anything previously cataloged on this shelf." : "Adds to the right end of this shelf.")
                    .font(.caption2).foregroundStyle(Theme.inkMuted)
            }
            .padding()
            .background(.ultraThinMaterial)
        }
    }

    private func offset(before segment: Int) -> Int {
        pipeline.segments.prefix(segment).reduce(0) { $0 + $1.books.count }
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 44)).foregroundStyle(Theme.signal)
            Text("Scan failed").font(Theme.display(28))
            Text(message).multilineTextAlignment(.center).foregroundStyle(Theme.inkMuted).padding(.horizontal)
            Button("Try again") { Task { await pipeline.run(input) } }.buttonStyle(SignalButtonStyle()).padding(.horizontal, 60)
            if message.contains("API key") {
                Button("Open Settings") { onClose(); router.tab = .settings }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Animated progress: a row of spines lights up as the pipeline advances.
private struct ScanProgress: View {
    let pipeline: ScanPipeline
    @State private var phase = 0.0

    private let stages: [ScanPipeline.Stage] = [.reading, .identifying, .cataloging]
    private let palette = ["#B23A2E", "#E8DCC0", "#1F3A5F", "#2E2E2E", "#6B8F71", "#C9A227", "#5B3A6B", "#D9D4C7", "#203B2C", "#8C2F1B", "#E1E1E1", "#30475E"]

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            TimelineView(.animation) { tl in
                let t = tl.date.timeIntervalSinceReferenceDate
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(0..<palette.count, id: \.self) { i in
                        let lit = Double(i) / Double(palette.count) <= max(pipeline.progress, 0.05)
                        SpineSwatch(colorHex: palette[i], accentHex: "#FFFFFF",
                                    width: 16 + CGFloat(i % 4) * 4, height: 110 + CGFloat((i * 29) % 50))
                            .opacity(lit ? 1 : 0.25)
                            .offset(y: lit ? 0 : sin(t * 3 + Double(i) * 0.6) * 3)
                    }
                }
                .overlay(alignment: .leading) {
                    // A scanning bar sweeping across the shelf.
                    Rectangle()
                        .fill(LinearGradient(colors: [.clear, Theme.signal.opacity(0.9), .clear], startPoint: .leading, endPoint: .trailing))
                        .frame(width: 30)
                        .offset(x: CGFloat((sin(t * 1.6) + 1) / 2) * 280 - 15)
                        .blendMode(.screen)
                }
            }
            .frame(height: 170)

            VStack(spacing: 8) {
                Text(pipeline.stage.title).font(Theme.display(30))
                Text(pipeline.detail).font(.callout).foregroundStyle(Theme.inkMuted).multilineTextAlignment(.center)
            }
            HStack(spacing: 8) {
                ForEach(stages, id: \.title) { s in
                    Capsule()
                        .fill(stageIndex(pipeline.stage) >= stageIndex(s) ? Theme.signal : Theme.panelRaised)
                        .frame(height: 6)
                }
            }
            .padding(.horizontal, 60)
            Spacer()
            Text("Spines are read on-device and by Claude; catalog records come from the Library of Congress and Open Library.")
                .font(.caption2).foregroundStyle(Theme.inkMuted).multilineTextAlignment(.center).padding()
        }
        .padding()
    }

    private func stageIndex(_ s: ScanPipeline.Stage) -> Int {
        switch s {
        case .stitching, .reading: return 0
        case .identifying: return 1
        case .cataloging: return 2
        case .review: return 3
        default: return -1
        }
    }
}

/// The captured photo with each detected spine outlined and numbered.
struct AnnotatedShelfPhoto: View {
    let segment: DraftSegment
    @Binding var selected: DraftBook.ID?
    let numberOffset: Int

    var body: some View {
        let ui = UIImage(cgImage: segment.image)
        let aspect = CGFloat(segment.image.width) / CGFloat(segment.image.height)
        ScrollView(.horizontal, showsIndicators: false) {
            Image(uiImage: ui)
                .resizable()
                .aspectRatio(aspect, contentMode: .fit)
                .frame(height: 260)
                .overlay {
                    GeometryReader { geo in
                        ForEach(Array(segment.books.enumerated()), id: \.element.id) { i, b in
                            let r = CGRect(x: b.box.minX * geo.size.width, y: b.box.minY * geo.size.height,
                                           width: b.box.width * geo.size.width, height: b.box.height * geo.size.height)
                            let isSel = selected == b.id
                            Rectangle()
                                .stroke(b.include ? (isSel ? Theme.signal : .white.opacity(0.8)) : .red.opacity(0.7),
                                        style: StrokeStyle(lineWidth: isSel ? 3 : 1.2, dash: b.include ? [] : [4]))
                                .background(isSel ? Theme.signal.opacity(0.2) : .clear)
                                .frame(width: r.width, height: r.height)
                                .position(x: r.midX, y: r.midY)
                                .onTapGesture { selected = b.id }
                            Text("\(numberOffset + i + 1)")
                                .font(Theme.mono(9, weight: .black))
                                .padding(2)
                                .background(isSel ? Theme.signal : .black.opacity(0.7))
                                .foregroundStyle(isSel ? .black : .white)
                                .position(x: r.midX, y: max(r.minY - 7, 7))
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

private struct DraftRow: View {
    let number: Int
    let draft: DraftBook
    let isSelected: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("\(number)").font(Theme.mono(12, weight: .bold)).foregroundStyle(Theme.inkMuted).frame(width: 24)
            SpineSwatch(colorHex: draft.colorHex, accentHex: draft.reading.accentColor, width: 14, height: 50)
            VStack(alignment: .leading, spacing: 3) {
                Text(draft.displayTitle).font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(draft.reading.title.isEmpty ? Theme.inkMuted : Theme.ink).lineLimit(2)
                if !draft.displayAuthors.isEmpty {
                    Text(draft.displayAuthors).font(.caption).foregroundStyle(Theme.inkMuted).lineLimit(1)
                }
                HStack(spacing: 6) {
                    if let call = draft.catalog?.lcCallNumber, !call.isEmpty {
                        Text(call).font(Theme.mono(10)).foregroundStyle(Theme.signal)
                    } else {
                        Text(draft.reading.title.isEmpty ? "unreadable" : "no LC record").font(Theme.mono(10)).foregroundStyle(Theme.inkMuted)
                    }
                    ConfidenceBar(value: draft.reading.confidence)
                }
            }
            Spacer()
            Button(action: toggle) {
                Image(systemName: draft.include ? "checkmark.circle.fill" : "circle")
                    .font(.title2).foregroundStyle(draft.include ? Theme.signal : Theme.inkMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(isSelected ? Theme.panelRaised : Theme.panel, in: RoundedRectangle(cornerRadius: 12))
        .opacity(draft.include ? 1 : 0.5)
    }
}

private struct ConfidenceBar: View {
    let value: Double
    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Theme.panelRaised)
            Capsule().fill(value > 0.75 ? Color.green : value > 0.45 ? .yellow : .red)
                .frame(width: 40 * max(0.05, min(value, 1)))
        }
        .frame(width: 40, height: 4)
    }
}

/// Correct a misread spine and re-run the catalog lookup.
private struct DraftEditor: View {
    @Binding var book: DraftBook
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var authors = ""
    @State private var searching = false

    var body: some View {
        NavigationStack {
            Form {
                Section("As read from the spine") {
                    Text(book.reading.spineText.isEmpty ? "—" : book.reading.spineText).font(.callout.italic())
                    if !book.reading.graphicNotes.isEmpty { Text(book.reading.graphicNotes).font(.caption).foregroundStyle(.secondary) }
                }
                Section("Correct identification") {
                    TextField("Title", text: $title)
                    TextField("Author(s), comma separated", text: $authors)
                    Button(searching ? "Searching…" : "Find LC record") {
                        Task { await search() }
                    }
                    .disabled(title.isEmpty || searching)
                }
                if let c = book.catalog {
                    Section("Catalog match") {
                        LabeledContent("Title", value: c.title)
                        LabeledContent("Call number", value: c.lcCallNumber.isEmpty ? "—" : c.lcCallNumber)
                        LabeledContent("Date", value: c.year)
                        LabeledContent("ISBN", value: c.isbn)
                        Button("Clear match", role: .destructive) { book.catalog = nil }
                    }
                }
                Section {
                    Toggle("Include in catalog", isOn: $book.include)
                }
            }
            .navigationTitle("Spine")
            .toolbar {
                Button("Done") {
                    // A hand-corrected title that no longer matches the catalog record invalidates it.
                    if let c = book.catalog, TextMatch.score(title, c.title) < 0.6 { book.catalog = nil }
                    book.reading.title = title
                    book.reading.authors = authors.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    dismiss()
                }
            }
            .onAppear {
                title = book.catalog?.title.nilIfEmpty ?? book.reading.title
                authors = book.displayAuthors
            }
        }
    }

    private func search() async {
        searching = true
        defer { searching = false }
        let a = authors.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        book.reading.title = title
        book.reading.authors = a
        book.catalog = await CatalogService().lookup(title: title, authors: a)
    }
}
