import SwiftUI

@main
struct FlashWatchApp: App {
    @StateObject private var flash = Flash()
    @StateObject private var speaker = Speaker.shared

    init() {
        UserDefaults.standard.register(defaults: [
            Prefs.readAloud: false,
            Prefs.flashVoice: true,
            Prefs.shortReplies: true,
        ])
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(flash)
                .environmentObject(speaker)
        }
    }
}

/// Pairing until there is a computer to talk to, then Flash.
struct RootView: View {
    @EnvironmentObject private var flash: Flash

    var body: some View {
        if flash.pairing == nil {
            NavigationStack { PairView() }
        } else {
            HomeView()
        }
    }
}

/// Where a tap goes.
enum Route: Hashable {
    case chat(String)
    case sparks
    case spark(String)
    case teams
    case team(String)
    case chats
    case settings
}
