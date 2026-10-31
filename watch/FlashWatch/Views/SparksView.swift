import SwiftUI
import WatchKit

/// Every spark: what each is doing, and which ones need you.
struct SparksView: View {
    @EnvironmentObject private var flash: Flash

    var body: some View {
        List {
            if flash.sparks.isEmpty {
                Text("No sparks yet. Make one in Flash on your computer.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(sorted) { spark in
                NavigationLink(value: Route.spark(spark.id)) {
                    SparkRow(spark: spark)
                }
            }
        }
        .navigationTitle("Sparks")
    }

    /// The ones that need you first.
    private var sorted: [Spark] {
        flash.sparks.sorted { ($0.needsYou ? 0 : 1, $0.name) < ($1.needsYou ? 0 : 1, $1.name) }
    }
}

struct SparkRow: View {
    let spark: Spark

    var body: some View {
        HStack(spacing: 8) {
            Face(name: spark.name, color: spark.color, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(spark.name).lineLimit(1)
                Text(spark.doing)
                    .font(.caption2)
                    .foregroundStyle(spark.needsYou ? Color.orange : Color.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

/// A spark's initial on its colour.
struct Face: View {
    let name: String
    let color: Color
    var size: CGFloat = 22

    var body: some View {
        Text(name.prefix(1).uppercased())
            .font(.system(size: size * 0.5, weight: .semibold, design: .rounded))
            .frame(width: size, height: size)
            .background(color, in: Circle())
            .foregroundStyle(.black.opacity(0.8))
    }
}

/// One spark: talk to it, answer what it waits on, run or pause it, and
/// its chats and its team's.
struct SparkView: View {
    let id: String
    @EnvironmentObject private var flash: Flash
    @State private var busy = false
    @State private var problem: String?
    @State private var opened: String?

    var body: some View {
        if let spark = flash.spark(id) {
            List {
                Section {
                    HStack(spacing: 8) {
                        Face(name: spark.name, color: spark.color, size: 32)
                        VStack(alignment: .leading) {
                            Text(spark.name).font(.headline)
                            if !spark.title.isEmpty {
                                Text(spark.title)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .listRowBackground(Color.clear)
                    Text(spark.doing)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }

                if spark.needsYou {
                    Section("Needs you") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(spark.pendingLabel).font(.footnote)
                            if !spark.pendingDetail.isEmpty {
                                Text(spark.pendingDetail)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(6)
                            }
                        }
                        Button("Approve") { act("approve", haptic: .success) }
                            .tint(.green)
                        Button("Deny") { act("deny", haptic: .failure) }
                            .tint(.red)
                    }
                }

                Section {
                    TextFieldLink(prompt: Text("Talk to \(spark.name)")) {
                        Label("Talk to \(spark.name)", systemImage: "mic.fill")
                    } onSubmit: { text in
                        Task { await talk(text) }
                    }
                    .listItemTint(spark.color)

                    if !spark.team.isEmpty, let team = flash.team(spark.team) {
                        NavigationLink(value: Route.team(team.id)) {
                            Row(title: team.name, icon: "person.3", count: team.unread)
                        }
                    }
                }

                let chats = flash.chats.filter { $0.spark == id }
                if !chats.isEmpty {
                    Section("Chats") {
                        ForEach(chats) { chat in
                            NavigationLink(value: Route.chat(chat.id)) {
                                ChatRow(chat: chat)
                            }
                        }
                    }
                }

                Section {
                    Button {
                        act("run", haptic: .start)
                    } label: {
                        Label("Run now", systemImage: "play.fill")
                    }
                    .disabled(spark.paused)
                    Button {
                        act(spark.paused ? "resume" : "pause", haptic: .click)
                    } label: {
                        Label(spark.paused ? "Resume" : "Pause",
                              systemImage: spark.paused ? "play.circle" : "pause.circle")
                    }
                }
                .disabled(busy)

                if let problem {
                    Text(problem)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .listRowBackground(Color.clear)
                }
            }
            .navigationTitle(spark.name)
            .navigationDestination(item: $opened) { chat in
                ChatView(id: chat)
            }
        } else {
            Text("This spark is gone.")
                .foregroundStyle(.secondary)
        }
    }

    private func act(_ what: String, haptic: WKHapticType) {
        Task {
            busy = true
            defer { busy = false }
            do {
                try await flash.sparkDo(what, id)
                problem = nil
                WKInterfaceDevice.current().play(haptic)
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func talk(_ text: String) async {
        do {
            opened = try await flash.startChat(text, spark: id)
        } catch {
            problem = error.localizedDescription
        }
    }
}
