import SwiftUI
import SwiftData

@main
struct ShelfmarkApp: App {
    @State private var router = Router()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(router)
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

    func find(_ book: Book) {
        highlighted = book
        tab = .finder
    }
}

struct RootView: View {
    @Environment(Router.self) private var router

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.tab) {
            CatalogView()
                .tabItem { Label("Catalog", systemImage: "books.vertical.fill") }
                .tag(Router.Tab.catalog)
            ScanView()
                .tabItem { Label("Scan", systemImage: "camera.viewfinder") }
                .tag(Router.Tab.scan)
            FindingAidView()
                .tabItem { Label("Finder", systemImage: "scope") }
                .tag(Router.Tab.finder)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "slider.horizontal.3") }
                .tag(Router.Tab.settings)
        }
        .background(Theme.ground)
    }
}
