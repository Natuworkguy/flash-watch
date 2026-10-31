import SwiftUI
import WatchKit

/// Where Flash is reached, and how replies are read.
struct SettingsView: View {
    @EnvironmentObject private var flash: Flash
    @AppStorage(Prefs.readAloud) private var readAloud = false
    @AppStorage(Prefs.flashVoice) private var flashVoice = true
    @AppStorage(Prefs.shortReplies) private var shortReplies = true
    @State private var confirming = false
    @State private var opening = false
    @State private var problem: String?

    var body: some View {
        List {
            Section {
                ForEach(flash.pairing?.addresses ?? [], id: \.self) { address in
                    HStack(spacing: 8) {
                        Image(systemName: FlashClient.isLocal(address) ? "wifi" : "globe")
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(FlashClient.isLocal(address) ? "On your Wi-Fi" : "From anywhere")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(FlashClient.hostOf(address))
                                .font(.footnote)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                        if address == flash.pairing?.address {
                            Image(systemName: "checkmark")
                                .font(.caption)
                                .foregroundStyle(Color.accentColor)
                                .accessibilityLabel("In use")
                        }
                    }
                }

                if flash.publicAddress == nil {
                    Button {
                        Task { await openPublicLink() }
                    } label: {
                        if opening {
                            HStack {
                                ProgressView().frame(width: 18)
                                Text("Opening a public link...")
                                    .font(.footnote)
                            }
                        } else {
                            Label("Reach from anywhere", systemImage: "globe")
                        }
                    }
                    .disabled(opening)
                }
                if let problem {
                    Text(problem)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Flash")
            } footer: {
                Text(flash.publicAddress == nil
                     ? "Turns on your computer's tunnel, so the watch reaches Flash away from your Wi-Fi too. It can take a minute."
                     : "The watch uses whichever one answers.")
            }

            Section("Replies") {
                Toggle("Read new replies aloud", isOn: $readAloud)
                Toggle("Flash's own voice", isOn: $flashVoice)
                Toggle("Short replies", isOn: $shortReplies)
            }

            Section {
                Button("Unpair", role: .destructive) {
                    confirming = true
                }
            } footer: {
                Text("To rename this watch or sign it out from the computer, use Watch in Flash's sidebar.")
            }
        }
        .navigationTitle("Settings")
        .task { await flash.syncAddresses(force: true) }
        .confirmationDialog("Unpair this watch?", isPresented: $confirming) {
            Button("Unpair", role: .destructive) { flash.unpair() }
        } message: {
            Text("You'll need a new code from your computer to pair again.")
        }
    }

    private func openPublicLink() async {
        opening = true
        problem = nil
        defer { opening = false }
        do {
            try await flash.openPublicLink()
            WKInterfaceDevice.current().play(.success)
        } catch {
            problem = error.localizedDescription
            WKInterfaceDevice.current().play(.failure)
        }
    }
}
