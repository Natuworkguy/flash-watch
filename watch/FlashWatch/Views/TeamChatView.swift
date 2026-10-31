import SwiftUI
import WatchKit

/// The teams, each with its chat and how much of it is unread.
struct TeamsView: View {
    @EnvironmentObject private var flash: Flash

    var body: some View {
        List(flash.teams) { team in
            NavigationLink(value: Route.team(team.id)) {
                HStack(spacing: 8) {
                    Circle().fill(team.color).frame(width: 10, height: 10)
                    Row(title: team.name, icon: "", count: team.unread)
                }
            }
        }
        .navigationTitle("Teams")
    }
}

/// A team's chat: what the sparks and you said, reactions, replies, and
/// every earlier version of a message a spark edited.
struct TeamChatView: View {
    let id: String
    @EnvironmentObject private var flash: Flash
    @EnvironmentObject private var speaker: Speaker
    @State private var entries: [TeamEntry] = []
    @State private var seq = 0
    @State private var typing: [String] = []
    @State private var loaded = false
    @State private var problem: String?
    @State private var replyingTo: TeamEntry?
    @State private var picked: TeamEntry?
    @State private var history: TeamEntry?

    private var team: Team? { flash.team(id) }

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if !loaded, problem == nil {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                    if loaded, entries.isEmpty {
                        Text("Nobody has said anything yet.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(entries) { entry in
                        EntryView(entry: entry, history: $history)
                            .onTapGesture { if !entry.isNews { picked = entry } }
                    }
                    if !typing.isEmpty {
                        Text(typingWords)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .italic()
                    }
                    if let problem {
                        Text(problem).font(.footnote).foregroundStyle(.red)
                    }
                    composer.id("end")
                }
                .padding(.horizontal, 2)
            }
            .onChange(of: entries.count) {
                withAnimation { scroller.scrollTo("end", anchor: .bottom) }
            }
        }
        .navigationTitle(team?.name ?? "Team")
        .navigationBarTitleDisplayMode(.inline)
        .task { await follow() }
        .sheet(item: $picked) { entry in
            NavigationStack {
                EntryActions(entry: entry, team: id, replyingTo: $replyingTo,
                             done: { picked = nil; Task { await load() } })
            }
        }
        .sheet(item: $history) { entry in
            Versions(entry: entry)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let to = replyingTo {
                HStack {
                    Text("Replying to \(who(to)): \(to.text)")
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button {
                        replyingTo = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Don't reply")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            TextFieldLink(prompt: Text("Message the team")) {
                Label("Message", systemImage: "mic.fill")
                    .frame(maxWidth: .infinity)
            } onSubmit: { text in
                Task { await say(text) }
            }
            .tint(team?.color ?? .accentColor)
        }
        .padding(.top, 4)
    }

    private var typingWords: String {
        let names = typing.compactMap { flash.spark($0)?.name }
        switch names.count {
        case 0: return ""
        case 1: return "\(names[0]) is typing..."
        case 2: return "\(names[0]) and \(names[1]) are typing..."
        default: return "\(names.count) sparks are typing..."
        }
    }

    private func who(_ entry: TeamEntry) -> String {
        entry.isMine ? "you" : entry.name.isEmpty ? (flash.spark(entry.spark)?.name ?? "a spark") : entry.name
    }

    private func say(_ text: String) async {
        do {
            try await flash.say(text, team: id, replyTo: replyingTo?.id ?? 0)
            replyingTo = nil
            await load()
        } catch {
            problem = error.localizedDescription
        }
    }

    private func follow() async {
        while !Task.isCancelled {
            await load()
            try? await Task.sleep(for: .seconds(typing.isEmpty ? 4 : 1.5))
        }
    }

    /// What is new since the last look, and what changed before it:
    /// reactions, and messages a spark edited.
    private func load() async {
        do {
            let chat = try await flash.teamChat(id, since: seq)
            let fresh = chat["entries"].array.map(TeamEntry.init)
            let changed = chat["changed"].array.map(TeamEntry.init)
            var all = entries
            for entry in changed {
                if let at = all.firstIndex(where: { $0.id == entry.id }) { all[at] = entry }
            }
            let known = Set(all.map(\.id))
            let added = fresh.filter { !known.contains($0.id) }
            all += added
            let before = entries.count
            entries = all
            seq = max(seq, chat["seq"].int)
            typing = chat["typing"].array.map { $0["spark"].string }
            problem = nil
            if loaded, before > 0, added.contains(where: { !$0.isMine && !$0.isNews }) {
                WKInterfaceDevice.current().play(.notification)
            }
            loaded = true
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// One message in a team chat.
struct EntryView: View {
    let entry: TeamEntry
    @Binding var history: TeamEntry?
    @EnvironmentObject private var flash: Flash

    private var spark: Spark? { flash.spark(entry.spark) }

    var body: some View {
        if entry.isNews {
            Text(entry.text)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)
        } else {
            VStack(alignment: entry.isMine ? .trailing : .leading, spacing: 3) {
                HStack(spacing: 4) {
                    if !entry.isMine {
                        Face(name: name, color: spark?.color ?? .accentColor, size: 16)
                    }
                    Text(entry.isMine ? "You" : name)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(entry.isMine ? Color.accentColor : (spark?.color ?? .secondary))
                    Text(ago(entry.at))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if !entry.replyText.isEmpty {
                    Text(entry.replyText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.leading, 6)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(.secondary).frame(width: 2)
                        }
                }

                Markdown(text: entry.text)
                    .foregroundStyle(entry.failed ? Color.red : Color.primary)

                HStack(spacing: 6) {
                    if entry.wasEdited {
                        Button {
                            history = entry
                        } label: {
                            Label("edited", systemImage: "clock.arrow.circlepath")
                                .font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Edited. See earlier versions")
                    }
                    if entry.files > 0 {
                        Label("\(entry.files)", systemImage: "paperclip")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(entry.reactions, id: \.emoji) { reaction in
                        Text("\(reaction.emoji)\(reaction.count > 1 ? " \(reaction.count)" : "")")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(reaction.mine ? Color.accentColor.opacity(0.35) : Color.white.opacity(0.1),
                                        in: Capsule())
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: entry.isMine ? .trailing : .leading)
        }
    }

    private var name: String {
        entry.name.isEmpty ? (spark?.name ?? "Spark") : entry.name
    }
}

/// What a tap on a message offers: a reaction, a reply, reading it
/// aloud, and its earlier versions.
struct EntryActions: View {
    let entry: TeamEntry
    let team: String
    @Binding var replyingTo: TeamEntry?
    let done: () -> Void
    @EnvironmentObject private var flash: Flash
    @EnvironmentObject private var speaker: Speaker

    /// The reactions Flash's page offers first.
    private let quick = ["👍", "❤️", "😂", "🎉", "👀", "🙏", "🔥", "✅"]

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4),
                          spacing: 4) {
                    ForEach(quick, id: \.self) { emoji in
                        let mine = entry.reactions.contains { $0.emoji == emoji && $0.mine }
                        Button(emoji) {
                            Task {
                                try? await flash.react(emoji, to: entry.id, team: team)
                                WKInterfaceDevice.current().play(.click)
                                done()
                            }
                        }
                        .buttonStyle(.plain)
                        .font(.title3)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(mine ? Color.accentColor.opacity(0.35) : Color.white.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }

                Button {
                    replyingTo = entry
                    done()
                } label: {
                    Label("Reply", systemImage: "arrowshape.turn.up.left")
                        .frame(maxWidth: .infinity)
                }

                Button {
                    speaker.toggle(entry.text, id: "team-\(team)-\(entry.id)", flash: flash)
                } label: {
                    Label("Read aloud", systemImage: "speaker.wave.2")
                        .frame(maxWidth: .infinity)
                }

                if entry.wasEdited {
                    NavigationLink {
                        Versions(entry: entry)
                    } label: {
                        Label("Earlier versions", systemImage: "clock.arrow.circlepath")
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }
}

/// Every version of an edited message, the one shown now first.
struct Versions: View {
    let entry: TeamEntry

    var body: some View {
        List {
            Section("Now") {
                VStack(alignment: .leading, spacing: 2) {
                    Markdown(text: entry.text)
                    Text(ago(entry.edited))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Before") {
                ForEach(Array(entry.versions.enumerated().reversed()), id: \.offset) { _, version in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(version.text)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text(ago(version.at))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Edits")
    }
}
