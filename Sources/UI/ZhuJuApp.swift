import SwiftUI

@main
struct ZhuJuApp: App {
    @StateObject private var library = MediaLibrary()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(library)
                .preferredColorScheme(.dark)
                .tint(Color(red: 1.0, green: 0.72, blue: 0.25))
        }
    }
}
