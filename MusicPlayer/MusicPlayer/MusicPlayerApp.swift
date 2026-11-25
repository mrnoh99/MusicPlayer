import SwiftUI

@main
struct MusicPlayerApp: App {
    @StateObject private var store = ScoreStore()
    @StateObject private var progress = ProgressStore()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(store)
                .environmentObject(progress)
        }
    }
}
