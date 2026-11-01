import SwiftUI

/// Pairing: the code Flash shows under Watch on the computer. It carries the
/// computer's address on the Wi-Fi, so it is all there is to type; an address
/// is asked for only away from it, for the public link.
struct PairView: View {
    @EnvironmentObject private var flash: Flash
    @State private var code = ""
    @State private var address = ""
    @State private var other = false
    @State private var working = false
    @State private var problem: String?

    private var parsed: (address: String?, code: String?) { FlashClient.pairingCode(code) }

    private var ready: Bool {
        parsed.code != nil && (parsed.address != nil || !address.isEmpty)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let note = flash.signedOutNote {
                    Label(note, systemImage: "lock")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }

                Text("On your computer, open Flash and pick **Watch** in the sidebar.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                TextField("Pairing code", text: $code)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                if other || (parsed.code != nil && parsed.address == nil) {
                    TextField("Address", text: $address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } else {
                    Button("Use another address") { other = true }
                        .font(.footnote)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }

                Button {
                    Task { await pair() }
                } label: {
                    if working {
                        ProgressView()
                    } else {
                        Text("Pair")
                            .frame(maxWidth: .infinity)
                    }
                }
                .tint(.accentColor)
                .disabled(working || !ready)

                if let problem {
                    Text(problem)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Flash")
        .onAppear {
            if address.isEmpty, !flash.lastAddress.isEmpty, !FlashClient.isLocal(flash.lastAddress) {
                address = flash.lastAddress
            }
        }
    }

    private func pair() async {
        working = true
        problem = nil
        defer { working = false }
        guard let secret = parsed.code else { return }
        // An address typed in wins: it is there because the code's one
        // could not be reached.
        let where_ = address.isEmpty ? (parsed.address ?? "") : address
        do {
            try await flash.pair(address: where_, code: secret)
        } catch {
            problem = error.localizedDescription
            code = ""
        }
    }
}
