import SwiftUI
import SwiftData

/// A queued scan: detailed live progress while it runs, then review and save.
struct ScanJobView: View {
    let job: ScanJob
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(Router.self) private var router
    @Environment(ScanQueue.self) private var queue
    @State private var selected: DraftBook.ID?
    @State private var editing: EditTarget?

    struct EditTarget: Identifiable { let segment: Int; let book: Int; var id: String { "\(segment)-\(book)" } }

    @MainActor private var pipeline: ScanPipeline { job.pipeline }

    var body: some View {
        NavigationStack {
            Group {
                switch pipeline.stage {
                case .review: review
                case .failed(let message): failure(message)
                default: ScanProgressDetail(job: job, place: job.isWaiting ? queue.place(of: job) : nil)
                }
            }
            .background(Theme.ground)
            .navigationTitle("Shelf \(job.shelfLabel)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(pipeline.stage.isFinished ? "Close" : "Keep scanning") { dismiss() }
                }
                if !pipeline.stage.isFinished {
                    ToolbarItem(placement: .destructiveAction) {
                        Button("Stop", role: .destructive) { queue.remove(job); dismiss() }
                    }
                }
            }
        }
        .sheet(item: $editing) { target in
            DraftEditor(book: Binding(
                get: { job.pipeline.segments[target.segment].books[target.book] },
                set: { job.pipeline.segments[target.segment].books[target.book] = $0 }))
        }
    }

    // MARK: Review

    @MainActor private var review: some View {
        let included = pipeline.allBooks.filter(\.include).count
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(pipeline.warnings, id: \.self) { w in
                        Label(w, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote).foregroundStyle(.yellow)
                            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    }
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
                                     toggle: { job.pipeline.segments[sIndex].books[bIndex].include.toggle() })
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
                    queue.save(job, context: context, router: router)
                    dismiss()
                } label: {
                    Text("Save \(included) books to \(job.shelfLabel)")
                }
                .buttonStyle(SignalButtonStyle())
                .disabled(included == 0)
                Text(job.mode == .replace ? "Replaces anything previously cataloged on this shelf." : "Adds to the right end of this shelf.")
                    .font(.caption2).foregroundStyle(Theme.inkMuted)
            }
            .padding()
            .background(.ultraThinMaterial)
        }
    }

    @MainActor private func offset(before segment: Int) -> Int {
        pipeline.segments.prefix(segment).reduce(0) { $0 + $1.books.count }
    }

    @MainActor private func failure(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 44)).foregroundStyle(Theme.signal)
            Text("Scan failed").font(Theme.display(28))
            Text(message).multilineTextAlignment(.center).foregroundStyle(Theme.inkMuted).padding(.horizontal)
            Button("Try again") { queue.retry(job) }.buttonStyle(SignalButtonStyle()).padding(.horizontal, 60)
            if message.contains("API key") {
                Button("Open Settings") { dismiss(); router.tab = .settings }
            }
            ActivityLog(lines: pipeline.activity).padding(.horizontal).padding(.top, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Live progress

/// How recently the scan heard anything. Green means data is flowing; amber means a quiet spell
/// (normal while Claude thinks); red means nothing for long enough that something may be wrong.
struct LiveIndicator: View {
    let lastActivity: Date
    let now: Date
    let active: Bool

    var body: some View {
        let quiet = now.timeIntervalSince(lastActivity)
        let (color, text): (Color, String) = {
            guard active else { return (Theme.inkMuted, "Idle") }
            if quiet < 15 { return (.green, "Live") }
            if quiet < 60 { return (.yellow, "Quiet for \(Int(quiet))s") }
            return (.red, "No response for \(Int(quiet))s")
        }()
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
                .opacity(active && quiet < 15 ? (Int(now.timeIntervalSince1970 * 2) % 2 == 0 ? 1 : 0.35) : 1)
            Text(text).font(Theme.mono(11, weight: .bold)).foregroundStyle(color)
        }
    }
}

struct ScanProgressDetail: View {
    let job: ScanJob
    let place: Int?
    @MainActor private var pipeline: ScanPipeline { job.pipeline }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { tl in
            let now = tl.date
            let p = pipeline.progress(at: now)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Headline
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(place != nil ? "Waiting in queue" : pipeline.stage.title).font(Theme.display(30))
                            Spacer()
                            Text("\(Int(p * 100))%").font(Theme.mono(26, weight: .black)).foregroundStyle(Theme.signal)
                        }
                        ProgressBar(value: p)
                        HStack {
                            LiveIndicator(lastActivity: pipeline.lastActivity, now: now, active: place == nil)
                            Spacer()
                            Text("Elapsed \(formatDuration(pipeline.elapsed(at: now)))")
                                .font(Theme.mono(11)).foregroundStyle(Theme.inkMuted)
                        }
                        if let place {
                            Text("\(place == 1 ? "Next up" : "\(place - 1) ahead of it"). Two shelves are processed at a time.")
                                .font(.footnote).foregroundStyle(Theme.inkMuted)
                        } else if !pipeline.detail.isEmpty {
                            Text(pipeline.detail).font(.callout).foregroundStyle(Theme.inkMuted)
                        }
                    }

                    StepList(pipeline: pipeline, now: now)

                    if !pipeline.tiles.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionLabel(text: "Claude · \(pipeline.spinesSoFar) spines so far")
                            ForEach(pipeline.tiles) { tile in
                                TileCard(tile: tile, count: pipeline.tiles.count, now: now)
                            }
                        }
                    }

                    if pipeline.stage == .cataloging {
                        VStack(alignment: .leading, spacing: 6) {
                            SectionLabel(text: "Catalog lookups · \(pipeline.catalogDone) of \(pipeline.catalogTotal)")
                            ForEach(pipeline.catalogInFlight, id: \.self) { t in
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.mini)
                                    Text(t).font(.footnote).lineLimit(1)
                                }
                            }
                        }
                    }

                    ActivityLog(lines: pipeline.activity)

                    Text("You can close this and keep photographing other shelves. Scans continue while you use the app; if you switch to another app, iOS allows only a short time before pausing them.")
                        .font(.caption).foregroundStyle(Theme.inkMuted)
                }
                .padding()
            }
        }
    }
}

@MainActor
private struct StepList: View {
    let pipeline: ScanPipeline
    let now: Date

    private enum StepState { case pending, active, done }

    var body: some View {
        let steps: [(String, StepState, String)] = [
            ("Prepare image", state(for: [.preparing, .stitching], after: [.identifying, .cataloging, .review]), ""),
            ("Read text on device", ocrState, ocrDetail),
            ("Identify spines with Claude", state(for: [.identifying], after: [.cataloging, .review]),
             pipeline.spinesSoFar > 0 ? "\(pipeline.spinesSoFar) found" : ""),
            ("Look up LC records", state(for: [.cataloging], after: [.review]),
             pipeline.catalogTotal > 0 ? "\(pipeline.catalogDone)/\(pipeline.catalogTotal)" : ""),
        ]
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                HStack(spacing: 12) {
                    Group {
                        switch step.1 {
                        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.signal)
                        case .active: ProgressView().controlSize(.small).tint(Theme.signal)
                        case .pending: Image(systemName: "circle").foregroundStyle(Theme.inkMuted)
                        }
                    }
                    .frame(width: 22)
                    Text(step.0).font(.system(size: 15, weight: step.1 == .active ? .bold : .regular))
                        .foregroundStyle(step.1 == .pending ? Theme.inkMuted : Theme.ink)
                    Spacer()
                    Text(step.2).font(Theme.mono(11)).foregroundStyle(Theme.inkMuted)
                }
                .padding(.vertical, 9)
                if i < steps.count - 1 { Divider().overlay(Theme.line).padding(.leading, 34) }
            }
        }
        .padding(.horizontal, 14)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
    }

    private func state(for active: [ScanPipeline.Stage], after: [ScanPipeline.Stage]) -> StepState {
        if after.contains(pipeline.stage) { return .done }
        if active.contains(pipeline.stage) { return .active }
        return .pending
    }

    private var ocrState: StepState {
        if pipeline.tiles.isEmpty { return pipeline.stage == .identifying ? .active : state(for: [], after: [.cataloging, .review]) }
        if pipeline.tiles.allSatisfy({ $0.phase != .queued && $0.phase != .ocr }) { return .done }
        return pipeline.tiles.contains { $0.phase == .ocr } ? .active : .pending
    }

    private var ocrDetail: String {
        let n = pipeline.tiles.reduce(0) { $0 + $1.ocrFragments }
        return n > 0 ? "\(n) fragments" : ""
    }
}

private struct TileCard: View {
    let tile: TileProgress
    let count: Int
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(count > 1 ? "Section \(tile.id + 1) of \(count)" : "Shelf photo")
                    .font(.system(size: 14, weight: .bold))
                Spacer()
                Text(phaseText).font(Theme.mono(11, weight: .bold)).foregroundStyle(phaseColor)
            }
            ProgressBar(value: tile.fraction(at: now), height: 4)
            if !tile.note.isEmpty {
                Text(tile.note).font(.caption).foregroundStyle(tile.phase == .failed ? .red : .yellow)
            }
            if (tile.phase == .thinking || tile.phase == .uploading) && !tile.thought.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "sparkle").font(.caption).foregroundStyle(Theme.signal)
                    Text(tile.thought).font(.caption.italic()).foregroundStyle(Theme.inkMuted).lineLimit(3)
                }
            }
            if !tile.titles.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(tile.titles.suffix(6).enumerated()), id: \.offset) { _, t in
                        HStack(spacing: 6) {
                            Rectangle().fill(Theme.signal).frame(width: 3, height: 12)
                            Text(t.isEmpty ? "Unidentified spine" : t).font(.caption).lineLimit(1)
                                .foregroundStyle(t.isEmpty ? Theme.inkMuted : Theme.ink)
                        }
                    }
                    if tile.titles.count > 6 {
                        Text("+ \(tile.titles.count - 6) earlier").font(Theme.mono(10)).foregroundStyle(Theme.inkMuted)
                    }
                }
                .animation(.snappy, value: tile.titles.count)
            }
        }
        .padding(12)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
    }

    private var phaseText: String {
        let t = Int(now.timeIntervalSince(tile.startedAt ?? now))
        switch tile.phase {
        case .queued: return "queued"
        case .ocr: return "reading text"
        case .uploading: return "sending"
        case .thinking: return "examining · \(t)s"
        case .writing: return "writing · \(tile.titles.count)"
        case .done: return "done · \(tile.titles.count)"
        case .failed: return "failed"
        }
    }

    private var phaseColor: Color {
        switch tile.phase {
        case .done: return .green
        case .failed: return .red
        case .queued: return Theme.inkMuted
        default: return Theme.signal
        }
    }
}

struct ActivityLog: View {
    let lines: [ActivityLine]
    @State private var expanded = false

    var body: some View {
        if !lines.isEmpty, let start = lines.first?.time {
            VStack(alignment: .leading, spacing: 6) {
                Button { withAnimation { expanded.toggle() } } label: {
                    HStack {
                        SectionLabel(text: "Activity")
                        Spacer()
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption).foregroundStyle(Theme.inkMuted)
                    }
                }
                .buttonStyle(.plain)
                ForEach(Array((expanded ? lines : Array(lines.suffix(4))).reversed())) { line in
                    HStack(alignment: .top, spacing: 8) {
                        Text(formatDuration(line.time.timeIntervalSince(start)))
                            .font(Theme.mono(10)).foregroundStyle(Theme.inkMuted).frame(width: 38, alignment: .leading)
                        Text(line.text).font(.caption).foregroundStyle(Theme.ink.opacity(0.85))
                    }
                }
            }
            .padding(12)
            .background(Theme.panel.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

struct ProgressBar: View {
    let value: Double
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.panelRaised)
                Capsule().fill(Theme.signal)
                    .frame(width: max(height, geo.size.width * min(max(value, 0), 1)))
                    .animation(.easeOut(duration: 0.5), value: value)
            }
        }
        .frame(height: height)
    }
}

func formatDuration(_ t: TimeInterval) -> String {
    let s = max(Int(t), 0)
    return String(format: "%d:%02d", s / 60, s % 60)
}

// MARK: - Queue card (shown on the Scan screen)

@MainActor
struct ScanJobCard: View {
    let job: ScanJob
    let place: Int?
    let open: () -> Void
    let save: () -> Void
    let retry: () -> Void
    let remove: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { tl in
            let p = job.pipeline
            HStack(spacing: 12) {
                thumb
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("Shelf \(job.shelfLabel)").font(.system(size: 15, weight: .bold))
                        Spacer()
                        if job.isRunning {
                            LiveIndicator(lastActivity: p.lastActivity, now: tl.date, active: true)
                        }
                    }
                    Text(statusLine).font(.caption).foregroundStyle(statusColor).lineLimit(1)
                    if job.isRunning {
                        ProgressBar(value: p.progress(at: tl.date), height: 5)
                        Text("\(formatDuration(p.elapsed(at: tl.date))) · \(p.spinesSoFar) spines")
                            .font(Theme.mono(10)).foregroundStyle(Theme.inkMuted)
                    }
                    if job.isReady {
                        HStack(spacing: 8) {
                            smallButton("Review", filled: false, action: open)
                            smallButton("Save", filled: true, action: save)
                        }
                    } else if job.isFailed {
                        HStack(spacing: 8) {
                            smallButton("Retry", filled: true, action: retry)
                            smallButton("Remove", filled: false, action: remove)
                        }
                    }
                }
            }
            .padding(12)
            .background(job.isReady ? Theme.signalSoft : Theme.panel, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(job.isReady ? Theme.signal.opacity(0.6) : .clear))
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
        }
    }

    private var thumb: some View {
        Group {
            if let t = job.thumbnail {
                Image(uiImage: t).resizable().scaledToFill()
            } else {
                Image(systemName: "video.fill").foregroundStyle(Theme.inkMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.panelRaised)
            }
        }
        .frame(width: 64, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var statusLine: String {
        if let place { return place == 1 ? "Waiting · next up" : "Waiting · \(place - 1) ahead" }
        switch job.pipeline.stage {
        case .review: return "Ready · \(job.pipeline.allBooks.count) books found"
        case .failed(let m): return m
        default:
            let d = job.pipeline.detail
            return d.isEmpty ? job.pipeline.stage.title : "\(job.pipeline.stage.title) · \(d)"
        }
    }

    private var statusColor: Color {
        if job.isReady { return Theme.signal }
        if job.isFailed { return .red }
        return Theme.inkMuted
    }

    private func smallButton(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .bold))
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(filled ? Theme.signal : Theme.panelRaised, in: Capsule())
                .foregroundStyle(filled ? Color.black : Theme.ink)
        }
        .buttonStyle(.plain)
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

struct ConfidenceBar: View {
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
