import SwiftUI

/// The first screen: a new chat by voice, the sparks and their teams,
/// and the latest chats.
struct HomeView: View {
    @EnvironmentObject private var flash: Flash
    @Environment(\.scenePhase) private var phase
    @State private var path = NavigationPath()
    @State private var starting = false
    @State private var problem: String?
    @ObservedObject private var notes = NoteDelegate.shared

    /// The chat on screen, whose replies need no notification.
    private var openChat: String { flash.onScreen }

    /// How many chats the first screen shows before "All chats".
    private let recent = 6

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let problem = problem ?? flash.problem {
                    Section {
                        Label(problem, systemImage: "wifi.exclamationmark")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    TextFieldLink(prompt: Text("Ask Flash")) {
                        HStack {
                            Label("New chat", systemImage: "square.and.pencil")
                            if starting {
                                Spacer()
                                ProgressView().frame(width: 18)
                            }
                        }
                    } onSubmit: { text in
                        Task { await start(text) }
                    }
                    .listItemTint(.accentColor)
                }

                Section {
                    NavigationLink(value: Route.briefing) {
                        Row(title: "Briefing", icon: "newspaper")
                    }
                    NavigationLink(value: Route.sparks) {
                        Row(title: "Sparks", icon: "sparkles",
                            count: flash.sparks.filter(\.needsYou).count,
                            warn: true)
                    }
                    if !flash.teams.isEmpty {
                        NavigationLink(value: Route.teams) {
                            Row(title: "Team chats", icon: "person.3",
                                count: flash.teams.reduce(0) { $0 + $1.unread })
                        }
                    }
                }

                Section("Chats") {
                    if flash.chats.isEmpty {
                        Text(flash.loaded ? "No chats yet." : "Loading...")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(flash.chats.prefix(recent)) { chat in
                        NavigationLink(value: Route.chat(chat.id)) {
                            ChatRow(chat: chat)
                        }
                    }
                    if flash.chats.count > recent {
                        NavigationLink(value: Route.chats) {
                            Text("All chats")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Flash")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: Route.settings) {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .chat(let id): ChatView(id: id)
                case .chats: ChatsView()
                case .sparks: SparksView()
                case .spark(let id): SparkView(id: id)
                case .teams: TeamsView()
                case .team(let id): TeamChatView(id: id)
                case .briefing: BriefingView()
                case .settings: SettingsView()
                }
            }
        }
        // Kept fresh while the watch shows it.
        // A tapped notification opens its chat.
        .onChange(of: notes.opened) {
            if let chat = notes.opened {
                notes.opened = nil
                path.append(Route.chat(chat))
            }
        }
        .onAppear { Notes.ask() }
        .task(id: phase) {
            guard phase == .active else { return }
            while !Task.isCancelled {
                await flash.refresh()
                await Notes.check(flash, quiet: openChat)
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func start(_ text: String) async {
        starting = true
        problem = nil
        defer { starting = false }
        do {
            let id = try await flash.startChat(text)
            path.append(Route.chat(id))
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// A row with an icon, a title, and a count when there is one.
struct Row: View {
    let title: String
    let icon: String
    var count = 0
    var warn = false

    var body: some View {
        HStack(spacing: 8) {
            if !icon.isEmpty {
                // Sized to fit a fixed box: a wide symbol such as three
                // people would otherwise run off the edge of the row.
                Image(systemName: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 20)
                    .foregroundStyle(Color.accentColor)
            }
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer()
            if count > 0 {
                Text("\(count)")
                    .font(.footnote.weight(.semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(warn ? Color.orange : Color.accentColor, in: Capsule())
                    .foregroundStyle(.black)
            }
        }
    }
}

/// A chat in a list: its title, and whether it is working or waiting.
struct ChatRow: View {
    @EnvironmentObject private var flash: Flash
    let chat: ChatItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if chat.pinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                }
                Text(chat.shownTitle)
                    .lineLimit(2)
            }
            HStack(spacing: 4) {
                if chat.busy {
                    ProgressView().frame(width: 12, height: 12).scaleEffect(0.5)
                    Text("Working")
                } else if let what = chat.waiting.first {
                    Image(systemName: "clock")
                    Text(what).lineLimit(1)
                } else if let spark = flash.spark(chat.spark) {
                    Circle().fill(spark.color).frame(width: 6, height: 6)
                    Text(spark.name).lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(ago(chat.updated))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// Every chat, newest first.
struct ChatsView: View {
    @EnvironmentObject private var flash: Flash

    var body: some View {
        List(flash.chats) { chat in
            NavigationLink(value: Route.chat(chat.id)) {
                ChatRow(chat: chat)
            }
        }
        .navigationTitle("Chats")
    }
}
