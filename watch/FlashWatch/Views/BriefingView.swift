import SwiftUI
import WatchKit

/// A card of Flash's briefing: a spark's report, an email, a reminder, news.
struct BriefingCard: Identifiable, Equatable, Hashable {
    let id: String
    var label: String
    var title: String
    var body: String
    var at: Double
    var chat: String

    init(_ json: JSON) {
        id = json["id"].string
        label = json["label"].string
        title = json["title"].string
        body = json["body"].string
        at = json["at"].double
        chat = json["chat"].string
    }
}

/// The briefing, a card at a time: read it, hear it, put it away.
struct BriefingView: View {
    @EnvironmentObject private var flash: Flash
    @EnvironmentObject private var speaker: Speaker
    @State private var cards: [BriefingCard] = []
    @State private var loaded = false
    @State private var problem: String?

    var body: some View {
        List {
            if !loaded, problem == nil {
                ProgressView().frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }
            if loaded, cards.isEmpty {
                Text("You're all caught up.")
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
            ForEach(cards) { card in
                NavigationLink {
                    BriefingDetail(card: card) { dismiss(card) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(card.label.uppercased())
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                            Spacer(minLength: 0)
                            Text(ago(card.at))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(card.title)
                            .font(.footnote.weight(.semibold))
                            .lineLimit(2)
                        if !card.body.isEmpty {
                            Text(card.body)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .swipeActions {
                    Button(role: .destructive) { dismiss(card) } label: {
                        Label("Done", systemImage: "checkmark")
                    }
                }
            }
            if let problem {
                Text(problem)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
            if cards.count > 1 {
                Button {
                    speaker.toggle(cards.map { "\($0.title). \($0.body)" }.joined(separator: "\n\n"),
                                   id: "briefing", flash: flash)
                } label: {
                    Label(speaker.speaking == "briefing" ? "Stop" : "Read it all",
                          systemImage: speaker.speaking == "briefing" ? "stop.fill" : "speaker.wave.2")
                }
            }
        }
        .navigationTitle("Briefing")
        .task { await load() }
        .onDisappear { if speaker.speaking == "briefing" { speaker.stop() } }
    }

    private func load() async {
        do {
            cards = try await flash.briefing().map(BriefingCard.init)
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
        loaded = true
    }

    private func dismiss(_ card: BriefingCard) {
        withAnimation { cards.removeAll { $0.id == card.id } }
        WKInterfaceDevice.current().play(.click)
        Task { try? await flash.dismissCard(card.id) }
    }
}

/// One card, whole.
struct BriefingDetail: View {
    let card: BriefingCard
    let done: () -> Void
    @EnvironmentObject private var flash: Flash
    @EnvironmentObject private var speaker: Speaker
    @Environment(\.dismiss) private var close

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(card.label.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(card.title)
                    .font(.headline)
                if !card.body.isEmpty {
                    Markdown(text: card.body)
                }
                HStack {
                    Button {
                        speaker.toggle("\(card.title). \(card.body)", id: "card-\(card.id)", flash: flash)
                    } label: {
                        Image(systemName: speaker.speaking == "card-\(card.id)" ? "stop.fill" : "speaker.wave.2")
                    }
                    .accessibilityLabel("Read aloud")
                    Button {
                        done()
                        close()
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .accessibilityLabel("Done with it")
                }
                if !card.chat.isEmpty {
                    NavigationLink(value: Route.chat(card.chat)) {
                        Label("Open the chat", systemImage: "bubble.left")
                    }
                }
            }
        }
        .navigationTitle(card.label)
    }
}
