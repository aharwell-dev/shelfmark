import SwiftUI
import SwiftData

@main
struct ShelfmarkApp: App {
    @State private var router = Router()
    @State private var queue = ScanQueue()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(router)
                .environment(queue)
                .preferredColorScheme(.dark)
                .tint(Theme.signal)
        }
        .modelContainer(for: [Bookcase.self, Shelf.self, ShelfPhoto.self, Book.self])
    }
}

/// App-wide navigation: lets any screen jump to the finding aid with a book highlighted.
@Observable
final class Router {
    enum Tab: Hashable { case catalog, scan, finder, settings }
    var tab: Tab = .catalog
    var highlighted: Book?
    /// Shelf being reviewed one book at a time (presented full screen from anywhere).
    var reviewShelf: Shelf?
    /// Bookcase shown as a full illustrated elevation.
    var fullBookcase: Bookcase?

    func find(_ book: Book) {
        highlighted = book
        tab = .finder
    }
}

struct RootView: View {
    @Environment(Router.self) private var router
    @Environment(ScanQueue.self) private var queue
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.tab) {
            CatalogView()
                .tabItem { Label("Catalog", systemImage: "books.vertical.fill") }
                .tag(Router.Tab.catalog)
            ScanView()
                .tabItem { Label("Scan", systemImage: "camera.viewfinder") }
                .tag(Router.Tab.scan)
                // Badge counts shelves still processing plus those ready to review.
                .badge(queue.jobs.count)
            FindingAidView()
                .tabItem { Label("Finder", systemImage: "scope") }
                .tag(Router.Tab.finder)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "slider.horizontal.3") }
                .tag(Router.Tab.settings)
        }
        .background(Theme.ground)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { BackupManager.backUpIfDue(context: context) }
        }
        .fullScreenCover(item: $router.reviewShelf) { shelf in
            ReviewModeView(shelf: shelf)
        }
        .fullScreenCover(item: $router.fullBookcase) { bookcase in
            BookcaseFullView(bookcase: bookcase)
        }
    }
}

/// Deletes a book, keeps the shelf's numbering continuous, and clears any highlight on it.
@MainActor
func deleteBook(_ book: Book, context: ModelContext, router: Router) {
    if router.highlighted == book { router.highlighted = nil }
    let shelf = book.shelf
    context.delete(book)
    try? context.save()
    shelf?.renumberBooks()
    try? context.save()
}
