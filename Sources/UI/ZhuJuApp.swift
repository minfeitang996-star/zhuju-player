import SwiftUI

@main
struct ZhuJuApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var library = MediaLibrary()

    init() {
        Prefs.migrateLayoutDefaults()
        Boot.mark("A app.init")
    }


    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(library)
                .preferredColorScheme(.dark)
                .tint(Color(red: 1.0, green: 0.72, blue: 0.25))
        }
    }
}
