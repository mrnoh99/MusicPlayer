import SwiftUI

@main
struct MusicPlayerApp: App {
    @StateObject private var store = ScoreStore()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(store)
        }
    }
}
