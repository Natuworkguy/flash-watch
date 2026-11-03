import SwiftUI

/// Pairing: the address Flash shows under Watch on the computer, and the
/// six digits beside it.
struct PairView: View {
    @EnvironmentObject private var flash: Flash
    @Environment(\.dismiss) private var dismiss
    /// Pairing one more computer, from Settings, rather than the first.
    var adding = false
    @State private var address = ""
    @State private var code = ""
    @State private var working = false
    @State private var problem: String?

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

                TextField("Address", text: $address)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                TextField("Code", text: $code)

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
                .disabled(working || address.isEmpty || code.filter(\.isNumber).count != 6)

                if let problem {
                    Text(problem)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Flash")
        .onAppear {
            if address.isEmpty && !adding { address = flash.lastAddress }
        }
    }

    private func pair() async {
        working = true
        problem = nil
        defer { working = false }
        do {
            try await flash.pair(address: address, code: code)
            if adding { dismiss() }
        } catch {
            problem = error.localizedDescription
            code = ""
        }
    }
}
