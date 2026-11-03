import SwiftUI
import UserNotifications

@main
struct FlashWatchApp: App {
    @StateObject private var flash = Flash()
    @StateObject private var speaker = Speaker.shared

    init() {
        UserDefaults.standard.register(defaults: [
            Prefs.readAloud: false,
            Prefs.flashVoice: true,
            Prefs.shortReplies: true,
            Prefs.notifyReplies: true,
            Prefs.notifyFlash: true,
            Prefs.shareLocation: false,
        ])
        UNUserNotificationCenter.current().delegate = NoteDelegate.shared
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(flash)
                .environmentObject(speaker)
        }
        // With the app closed, watchOS wakes it now and then: what Flash
        // had to say since shows as notifications.
        .backgroundTask(.appRefresh(Notes.refreshID)) {
            let flash = await Flash()
            await Notes.check(flash)
            await Notes.schedule()
        }
    }
}

/// Pairing until there is a computer to talk to, then Flash.
struct RootView: View {
    @EnvironmentObject private var flash: Flash
    @Environment(\.scenePhase) private var phase

    var body: some View {
        Group {
            if flash.pairing == nil {
                NavigationStack { PairView() }
            } else {
                HomeView()
            }
        }
        .onChange(of: phase) {
            if phase == .background, flash.pairing != nil { Notes.schedule() }
            if phase == .active, flash.pairing != nil { Locator.shared.update(flash) }
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
    case briefing
    case settings
}
