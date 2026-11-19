import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers

/// Choose a bookcase and shelf, then capture it by photo or video.
struct ScanView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Bookcase.sortOrder) private var bookcases: [Bookcase]

    @State private var selectedCase: Bookcase?
    @State private var selectedShelf: Shelf?
    @State private var saveMode: SaveMode = .replace
    @State private var showCamera = false
    @State private var showNewCase = false
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var pendingScan: PendingScan?
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    step(1, "Choose a bookcase")
                    caseChips

                    if let bookcase = selectedCase {
                        step(2, "Tap the shelf you're scanning")
                        BookcasePicker(bookcase: bookcase, selected: $selectedShelf)

                        if let shelf = selectedShelf {
                            step(3, "Capture shelf \(shelf.label)")
                            captureControls(shelf)
                        }
                    }
                    tips
                }
                .padding()
            }
            .background(Theme.ground)
            .navigationTitle("Scan")
            .sheet(isPresented: $showNewCase) {
                BookcaseEditor(bookcase: nil, nextOrder: bookcases.count) { created in
                    selectedCase = created
                    selectedShelf = created.orderedShelves.first
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { result in
                    showCamera = false
                    let next: PendingScan? = switch result {
                    case .photo(let img): PendingScan(input: .photos([img]))
                    case .video(let url): PendingScan(input: .video(url))
                    case nil: nil
                    }
                    // Let the camera finish dismissing before presenting the scan session.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { pendingScan = next }
                }
                .ignoresSafeArea()
            }
            .fullScreenCover(item: $pendingScan) { pending in
                if let shelf = selectedShelf {
                    ScanSessionView(input: pending.input, shelf: shelf, mode: saveMode) { pendingScan = nil }
                }
            }
            .onChange(of: pickerItems) { _, items in
                guard !items.isEmpty else { return }
                Task { await loadPicked(items) }
            }
            .alert("Couldn't load media", isPresented: Binding(get: { loadError != nil }, set: { if !$0 { loadError = nil } })) {
                Button("OK") { loadError = nil }
            } message: { Text(loadError ?? "") }
            .onAppear {
                if selectedCase == nil { selectedCase = bookcases.first }
                if selectedShelf == nil { selectedShelf = selectedCase?.orderedShelves.first }
            }
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(spacing: 10) {
            Text("\(n)")
                .font(Theme.mono(14, weight: .black))
                .frame(width: 26, height: 26)
                .background(Theme.signal, in: Circle())
                .foregroundStyle(.black)
            Text(text).font(Theme.display(22))
        }
    }

    private var caseChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(bookcases) { bc in
                    Button {
                        withAnimation(.snappy) {
                            selectedCase = bc
                            selectedShelf = bc.orderedShelves.first
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(bc.code).font(Theme.display(28))
                            Text(bc.name).font(.caption).lineLimit(1)
                        }
                        .frame(width: 96, alignment: .leading)
                        .padding(12)
                        .background(selectedCase == bc ? Theme.signal : Theme.panel, in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(selectedCase == bc ? Color.black : Theme.ink)
                    }
                    .buttonStyle(.plain)
                }
                Button { showNewCase = true } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "plus").font(.title2.weight(.bold))
                        Text("New case").font(.caption)
                    }
                    .frame(width: 96, height: 52)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1.5, dash: [5])))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func captureControls(_ shelf: Shelf) -> some View {
        VStack(spacing: 12) {
            if !shelf.books.isEmpty {
                Picker("When saving", selection: $saveMode) {
                    ForEach(SaveMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(saveMode == .replace
                     ? "Shelf \(shelf.label) has \(shelf.books.count) books. A new scan will replace them."
                     : "New books will be added after the \(shelf.books.count) already on shelf \(shelf.label). Use this to scan a long shelf in sections, left to right.")
                    .font(.footnote).foregroundStyle(Theme.inkMuted)
            }
            HStack(spacing: 12) {
                Button { showCamera = true } label: {
                    Label("Camera", systemImage: "camera.fill")
                }
                .buttonStyle(SignalButtonStyle())
                PhotosPicker(selection: $pickerItems, maxSelectionCount: 6,
                             matching: .any(of: [.images, .videos])) {
                    Label("Library", systemImage: "photo.on.rectangle")
                        .font(.system(size: 16, weight: .bold))
                        .padding(.vertical, 14)
                        .frame(maxWidth: .infinity)
                        .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private var tips: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "For best results")
            Label("Stand square to the shelf; fill the frame with one shelf.", systemImage: "rectangle.dashed")
            Label("For long shelves, record a slow, level video pan from left to right, or take several photos and choose “Add to right end.”", systemImage: "video")
            Label("Even, bright light. Avoid glare on glossy jackets.", systemImage: "sun.max")
        }
        .font(.footnote)
        .foregroundStyle(Theme.inkMuted)
        .padding(14)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
    }

    private func loadPicked(_ items: [PhotosPickerItem]) async {
        defer { pickerItems = [] }
        // A single video becomes a panorama; otherwise photos are treated as left-to-right sections.
        if let videoItem = items.first(where: { $0.supportedContentTypes.contains { $0.conforms(to: .movie) } }) {
            do {
                if let movie = try await videoItem.loadTransferable(type: PickedMovie.self) {
                    pendingScan = PendingScan(input: .video(movie.url))
                }
            } catch { loadError = error.localizedDescription }
            return
        }
        var images: [UIImage] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                images.append(img)
            }
        }
        if images.isEmpty { loadError = "None of the selected items could be read as photos." }
        else { pendingScan = PendingScan(input: .photos(images)) }
    }
}

private struct PendingScan: Identifiable {
    let id = UUID()
    let input: ScanInput
}

/// A bookcase drawn as an elevation; each shelf is tappable.
struct BookcasePicker: View {
    let bookcase: Bookcase
    @Binding var selected: Shelf?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(bookcase.orderedShelves) { shelf in
                Button { withAnimation(.snappy) { selected = shelf } } label: {
                    HStack(spacing: 10) {
                        Text("\(shelf.number)")
                            .font(Theme.mono(13, weight: .bold))
                            .frame(width: 22)
                            .foregroundStyle(selected == shelf ? Theme.signal : Theme.inkMuted)
                        ZStack(alignment: .bottomLeading) {
                            Rectangle().fill(selected == shelf ? Theme.signalSoft : Color.black.opacity(0.35))
                            if shelf.books.isEmpty {
                                Text("not scanned").font(Theme.mono(11)).foregroundStyle(Theme.inkMuted)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            } else {
                                MiniShelf(books: shelf.orderedBooks)
                            }
                        }
                        .frame(height: 54)
                        .overlay(Rectangle().stroke(selected == shelf ? Theme.signal : .clear, lineWidth: 2))
                    }
                    .padding(.vertical, 5)
                    .overlay(alignment: .bottom) { Rectangle().fill(Theme.wood).frame(height: 5).padding(.leading, 32) }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(Theme.wood.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Spines in proportion, for small previews.
struct MiniShelf: View {
    let books: [Book]
    var body: some View {
        GeometryReader { geo in
            let total = max(books.reduce(0) { $0 + $1.drawingWidth }, 0.001)
            let scale = min(geo.size.width / total, 30 / (books.map(\.drawingWidth).max() ?? 1))
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(books) { b in
                    Rectangle()
                        .fill(Color(hex: b.colorHex, fallback: .gray))
                        .frame(width: max(b.drawingWidth * scale, 1.5),
                               height: geo.size.height * CGFloat(0.72 + 0.28 * min(1, (b.boxY1 - b.boxY0) / 0.8)))
                        .overlay(alignment: .trailing) { Rectangle().fill(.black.opacity(0.3)).frame(width: 0.5) }
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }
}
