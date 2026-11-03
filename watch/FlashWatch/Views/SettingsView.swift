import SwiftUI
import WatchKit

/// Where Flash is reached, and how replies are read.
struct SettingsView: View {
    @EnvironmentObject private var flash: Flash
    @AppStorage(Prefs.readAloud) private var readAloud = false
    @AppStorage(Prefs.flashVoice) private var flashVoice = true
    @AppStorage(Prefs.shortReplies) private var shortReplies = true
    @AppStorage(Prefs.notifyReplies) private var notifyReplies = true
    @AppStorage(Prefs.notifyFlash) private var notifyFlash = true
    @AppStorage(Prefs.shareLocation) private var shareLocation = false
    @ObservedObject private var locator = Locator.shared
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

            Section {
                ForEach(flash.servers) { server in
                    Button {
                        flash.use(server.id)
                        Task { await flash.refresh() }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "desktopcomputer")
                                .foregroundStyle(.secondary)
                                .frame(width: 18)
                            Text(Flash.label(server))
                                .font(.footnote)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                            if server.id == flash.pairing?.id {
                                Image(systemName: "checkmark")
                                    .font(.caption)
                                    .foregroundStyle(Color.accentColor)
                                    .accessibilityLabel("In use")
                            }
                        }
                    }
                }
                NavigationLink {
                    PairView(adding: true)
                } label: {
                    Label("Pair another computer", systemImage: "plus")
                }
            } header: {
                Text("Computers")
            } footer: {
                Text("The watch talks to the one with a check. Tap another to switch.")
            }

            Section {
                Toggle("Replies", isOn: $notifyReplies)
                Toggle("Questions and Flash's notifications", isOn: $notifyFlash)
            } header: {
                Text("Notify me")
            } footer: {
                Text("While Flash is open on the watch, at once. Closed, watchOS checks a few times an hour.")
            }

            Section("Replies") {
                Toggle("Read new replies aloud", isOn: $readAloud)
                Toggle("Flash's own voice", isOn: $flashVoice)
                Toggle("Short replies", isOn: $shortReplies)
            }

            Section {
                Toggle("Let Flash see my location", isOn: $shareLocation)
                if shareLocation, let trouble = locator.problem {
                    Text(trouble)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Location")
            } footer: {
                Text("On, the watch tells Flash where it is when you use it, so Flash can answer \"near me\". Off, it finds nothing and sends nothing, and Flash forgets the last place.")
            }

            Section {
                Button("Unpair this computer", role: .destructive) {
                    confirming = true
                }
            } footer: {
                Text("Unpairs only the computer in use. To rename this watch or sign it out from the computer, use Watch in Flash's sidebar.")
            }
        }
        .navigationTitle("Settings")
        .task { await flash.syncAddresses(force: true) }
        .onChange(of: shareLocation) {
            if shareLocation {
                Locator.shared.update(flash, force: true)
            } else {
                Locator.shared.stop(flash)
            }
        }
        .confirmationDialog("Unpair from \(flash.pairing.map(Flash.label) ?? "this computer")?", isPresented: $confirming) {
            Button("Unpair", role: .destructive) { flash.unpair() }
        } message: {
            Text("You'll need a new code from that computer to pair again.")
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
