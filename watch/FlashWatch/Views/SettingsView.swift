import SwiftUI

/// The computer this watch is paired with, and how replies are read.
struct SettingsView: View {
    @EnvironmentObject private var flash: Flash
    @AppStorage(Prefs.readAloud) private var readAloud = false
    @AppStorage(Prefs.flashVoice) private var flashVoice = true
    @AppStorage(Prefs.shortReplies) private var shortReplies = true
    @State private var confirming = false

    var body: some View {
        List {
            Section("Replies") {
                Toggle("Read new replies aloud", isOn: $readAloud)
                Toggle("Flash's own voice", isOn: $flashVoice)
                Toggle("Short replies", isOn: $shortReplies)
            }

            Section {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Paired with")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(flash.pairing?.address ?? "")
                        .font(.footnote)
                }
                Button("Unpair", role: .destructive) {
                    confirming = true
                }
            } footer: {
                Text("To sign this watch out from the computer, use Watch in Flash's sidebar.")
            }
        }
        .navigationTitle("Settings")
        .confirmationDialog("Unpair this watch?", isPresented: $confirming) {
            Button("Unpair", role: .destructive) { flash.unpair() }
        } message: {
            Text("You'll need a new code from your computer to pair again.")
        }
    }
}
