import AVFoundation
import SwiftUI

/// The names of the watch's own settings.
enum Prefs {
    /// Each new reply read out as it arrives, in an open chat.
    static let readAloud = "readAloud"
    /// Flash's own voice from the computer, rather than the watch's.
    static let flashVoice = "flashVoice"
    /// Messages sent as spoken, so replies come back short.
    static let shortReplies = "shortReplies"
    /// A notification when a reply comes in.
    static let notifyReplies = "notifyReplies"
    /// A notification for Flash's own, its questions, and sparks' mentions.
    static let notifyFlash = "notifyFlash"
}

/// Reads replies aloud: in Flash's own voice when the computer has one
/// set up, in the watch's otherwise.
@MainActor
final class Speaker: NSObject, ObservableObject {
    static let shared = Speaker()

    /// What is being read now, by the id its view gave it.
    @Published private(set) var speaking: String?

    private let synthesizer = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var job: Task<Void, Never>?

    override private init() {
        super.init()
        synthesizer.delegate = self
    }

    func toggle(_ text: String, id: String, flash: Flash) {
        if speaking == id {
            stop()
        } else {
            say(text, id: id, flash: flash)
        }
    }

    func say(_ text: String, id: String, flash: Flash) {
        stop()
        let words = Self.speakable(text)
        guard !words.isEmpty else { return }
        speaking = id
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)

        let flashVoice = UserDefaults.standard.object(forKey: Prefs.flashVoice) as? Bool ?? true
        guard flashVoice else { return speakHere(words) }
        job = Task {
            let audio = try? await flash.voice(words)
            guard !Task.isCancelled, speaking == id else { return }
            if let audio, let player = try? AVAudioPlayer(data: audio) {
                self.player = player
                player.delegate = self
                player.play()
            } else {
                speakHere(words)
            }
        }
    }

    func stop() {
        job?.cancel()
        job = nil
        player?.stop()
        player = nil
        synthesizer.stopSpeaking(at: .immediate)
        finished()
    }

    private func speakHere(_ words: String) {
        let utterance = AVSpeechUtterance(string: words)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    private func finished() {
        speaking = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// TEXT without its markdown: what reads well out loud. Code is
    /// skipped, since nobody wants it spelled out.
    static func speakable(_ text: String) -> String {
        var out: [String] = []
        var inCode = false
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inCode.toggle()
                if inCode { out.append("Here's some code.") }
                continue
            }
            if inCode { continue }
            var said = line
            // [words](link) says the words.
            said = said.replacingOccurrences(
                of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            said = said.replacingOccurrences(
                of: #"^\s*(#+|[-*+]|\d+\.|>)\s+"#, with: "", options: .regularExpression)
            said = said.replacingOccurrences(of: #"[*_`~|]"#, with: "", options: .regularExpression)
            out.append(said)
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension Speaker: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in if !self.synthesizer.isSpeaking { self.finished() } }
    }
}

extension Speaker: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            if self.player === player {
                self.player = nil
                self.finished()
            }
        }
    }
}
