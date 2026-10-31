import SwiftUI
import WatchKit

/// What a chat's log shows on a watch: the conversation, the steps
/// folded into one line each, and questions to answer.
enum Block: Identifiable, Equatable {
    case user(Int, String)
    case reply(Int, String)
    case steps(Int, [String])
    case ask(Int, id: String, question: String, answer: String)
    case error(Int, String)
    case note(Int, String, icon: String)

    var id: Int {
        switch self {
        case .user(let n, _), .reply(let n, _), .steps(let n, _), .error(let n, _): return n
        case .ask(let n, _, _, _), .note(let n, _, _): return n
        }
    }

    /// LOG as blocks. Tool calls in a row become one block; what the
    /// page draws as a card gets a line saying what it is.
    static func from(_ log: [JSON]) -> [Block] {
        var answers: [String: String] = [:]
        for entry in log where entry["type"].string == "answered" {
            answers[entry["id"].string] = entry["answer"].string
        }

        var blocks: [Block] = []
        for (n, entry) in log.enumerated() {
            let text = entry["text"].string
            switch entry["type"].string {
            case "user":
                blocks.append(.user(n, text))
            case "assistant":
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    blocks.append(.reply(n, text))
                }
            case "tool":
                let label = entry["label"].string
                if case .steps(let at, let labels)? = blocks.last {
                    blocks[blocks.count - 1] = .steps(at, labels + [label])
                } else {
                    blocks.append(.steps(n, [label]))
                }
            case "ask":
                let id = entry["id"].string
                blocks.append(.ask(n, id: id, question: entry["question"].string,
                                   answer: answers[id] ?? ""))
            case "error":
                blocks.append(.error(n, text))
            case "note":
                blocks.append(.note(n, text, icon: "info.circle"))
            case "wait":
                blocks.append(.note(n, "Waiting: \(entry["what"].string)", icon: "clock"))
            case "file":
                let name = entry["name"].string
                blocks.append(.note(n, name.isEmpty ? "A file" : name, icon: "paperclip"))
            case "chess", "course", "debate", "browser":
                blocks.append(.note(n, "A \(entry["type"].string) is open on your computer.",
                                    icon: "desktopcomputer"))
            default:
                break
            }
        }
        return blocks
    }
}

/// One chat: read it, answer what it asks, reply by voice, stop it.
struct ChatView: View {
    let id: String
    @EnvironmentObject private var flash: Flash
    @EnvironmentObject private var speaker: Speaker
    @AppStorage(Prefs.readAloud) private var readAloud = false
    @State private var chat: ChatDetail?
    @State private var problem: String?
    @State private var sending = false

    private var blocks: [Block] { Block.from(chat?.log ?? []) }
    private var busy: Bool { chat?.item.busy ?? false }

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if chat == nil, problem == nil {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                    ForEach(blocks) { block in
                        BlockView(block: block, chat: id)
                    }
                    if busy {
                        Working(partial: chat?.partial ?? "", thinking: chat?.thinking ?? "")
                    }
                    ForEach(chat?.queued ?? [], id: \.self) { text in
                        Label(text, systemImage: "clock")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    if let problem {
                        Text(problem).font(.footnote).foregroundStyle(.red)
                    }
                    composer
                        .id("end")
                }
                .padding(.horizontal, 2)
            }
            .onChange(of: blocks.count) {
                withAnimation { scroller.scrollTo("end", anchor: .bottom) }
            }
            .onAppear { scroller.scrollTo("end", anchor: .bottom) }
        }
        .navigationTitle(chat?.item.shownTitle ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
        .task { await follow() }
        .onDisappear { speaker.stop() }
    }

    private var composer: some View {
        HStack(spacing: 6) {
            TextFieldLink(prompt: Text(busy ? "Add to this" : "Reply")) {
                Label(sending ? "Sending" : "Reply", systemImage: "mic.fill")
                    .frame(maxWidth: .infinity)
            } onSubmit: { text in
                Task { await send(text) }
            }
            .disabled(sending)
            .tint(.accentColor)

            if busy {
                Button {
                    Task { try? await flash.stop(id) }
                } label: {
                    Image(systemName: "stop.fill")
                }
                .frame(width: 44)
                .tint(.red)
                .accessibilityLabel("Stop")
            }
        }
        .padding(.top, 4)
    }

    private func send(_ text: String) async {
        sending = true
        defer { sending = false }
        do {
            try await flash.send(text, to: id)
            await load()
        } catch {
            problem = error.localizedDescription
        }
    }

    /// Reads the chat again and again while it is open: quickly while
    /// Flash works on it, slowly otherwise.
    private func follow() async {
        while !Task.isCancelled {
            await load()
            try? await Task.sleep(for: .seconds(busy ? 1.2 : 4))
        }
    }

    private func load() async {
        do {
            let fresh = try await flash.chat(id)
            let wasBusy = busy
            let before = chat.map { Block.from($0.log).count } ?? -1
            chat = fresh
            problem = nil
            // A turn just ended while you watched: a tap on the wrist,
            // and the reply read out if you asked for that.
            if wasBusy, !fresh.item.busy, before >= 0 {
                WKInterfaceDevice.current().play(.notification)
                if readAloud, case .reply(let n, let text)? = Block.from(fresh.log).last {
                    speaker.say(text, id: "\(id)-\(n)", flash: flash)
                }
            }
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// A block of a chat, drawn.
struct BlockView: View {
    let block: Block
    let chat: String
    @EnvironmentObject private var flash: Flash
    @EnvironmentObject private var speaker: Speaker
    @State private var open = false
    @State private var answering = false

    var body: some View {
        switch block {
        case .user(_, let text):
            HStack {
                Spacer(minLength: 16)
                Text(text)
                    .font(.footnote)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.accentColor.opacity(0.28),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

        case .reply(let n, let text):
            VStack(alignment: .leading, spacing: 4) {
                Markdown(text: text)
                let key = "\(chat)-\(n)"
                Button {
                    speaker.toggle(text, id: key, flash: flash)
                } label: {
                    Image(systemName: speaker.speaking == key ? "stop.circle" : "speaker.wave.2")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(speaker.speaking == key ? "Stop reading" : "Read aloud")
            }

        case .steps(_, let labels):
            Button {
                withAnimation { open.toggle() }
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Label(labels.count == 1 ? labels[0] : "\(labels.count) steps",
                          systemImage: "gearshape.2")
                        .lineLimit(open ? nil : 1)
                    if open, labels.count > 1 {
                        ForEach(Array(labels.enumerated()), id: \.offset) { _, label in
                            Text(label).lineLimit(2)
                        }
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

        case .ask(_, let id, let question, let answer):
            VStack(alignment: .leading, spacing: 6) {
                Label("Flash asks", systemImage: "hand.raised")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                Text(question.components(separatedBy: "\n").first ?? question)
                    .font(.footnote)
                let detail = question.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(.caption2, design: .monospaced))
                        .lineLimit(6)
                        .foregroundStyle(.secondary)
                }
                if answer.isEmpty {
                    HStack {
                        Button("Allow") { Task { await reply(id, yes: true) } }
                            .tint(.green)
                        Button("Deny") { Task { await reply(id, yes: false) } }
                            .tint(.red)
                    }
                    .disabled(answering)
                } else {
                    Text(answer.lowercased().hasPrefix("y") ? "Allowed" : "Denied")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .background(Color.orange.opacity(0.14),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))

        case .error(_, let text):
            Label(text, systemImage: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(.red)

        case .note(_, let text, let icon):
            Label(text, systemImage: icon)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func reply(_ id: String, yes: Bool) async {
        answering = true
        defer { answering = false }
        try? await flash.answer(id, yes: yes)
        WKInterfaceDevice.current().play(yes ? .success : .failure)
    }
}

/// Flash at work: what it is writing so far, or what it is doing.
struct Working: View {
    let partial: String
    let thinking: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !partial.isEmpty {
                Markdown(text: partial)
            }
            HStack(spacing: 6) {
                ProgressView().frame(width: 14, height: 14).scaleEffect(0.6)
                Text(partial.isEmpty && !thinking.isEmpty ? "Thinking" : "Working")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A reply's markdown, as much of it as a watch can show: inline styles,
/// headings in bold, lists as they are, and code in a box.
struct Markdown: View {
    let text: String

    private struct Part: Identifiable {
        let id: Int
        let code: Bool
        let text: String
    }

    private var parts: [Part] {
        var parts: [Part] = []
        var lines: [String] = []
        var code = false
        func flush() {
            let joined = lines.joined(separator: "\n")
            if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append(Part(id: parts.count, code: code, text: joined))
            }
            lines = []
        }
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                flush()
                code.toggle()
            } else {
                lines.append(line)
            }
        }
        flush()
        return parts
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(parts) { part in
                if part.code {
                    Text(part.text)
                        .font(.system(.caption2, design: .monospaced))
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    Text(Self.styled(part.text))
                        .font(.footnote)
                }
            }
        }
    }

    static func styled(_ text: String) -> AttributedString {
        let plain = text.components(separatedBy: "\n").map { line -> String in
            guard let hashes = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) else {
                return line
            }
            return "**\(line[hashes.upperBound...])**"
        }.joined(separator: "\n")
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: plain, options: options)) ?? AttributedString(text)
    }
}
