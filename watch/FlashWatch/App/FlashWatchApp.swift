import SwiftUI
import UserNotifications

@main
struct FlashWatchApp: App {
    @StateObject private var flash = Flash()
    @StateObject private var speaker = Speaker.shared
    @StateObject private var calls = Calls.shared

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
        Notes.register()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(flash)
                .environmentObject(speaker)
                .environmentObject(calls)
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
    @EnvironmentObject private var calls: Calls

    var body: some View {
        Group {
            if flash.pairing == nil {
                NavigationStack { PairView() }
            } else {
                HomeView()
            }
        }
        // A spark calling rings over whatever is on screen, and the call
        // stays there until it is over.
        .fullScreenCover(isPresented: .constant(calls.showing)) {
            CallView()
                .environmentObject(flash)
                .environmentObject(calls)
        }
        // Calls are looked for while the app is open, wrist down too.
        .task(id: phase) {
            guard phase != .background else { return }
            await calls.watch(flash)
        }
        .onChange(of: phase) {
            if phase == .background, flash.pairing != nil { Notes.schedule() }
            if phase == .active, flash.pairing != nil {
                Locator.shared.update(flash)
                Battery.report(flash)
            }
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
