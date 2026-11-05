import SwiftUI

/// A spark calling, and the call once it is picked up.
struct CallView: View {
    @EnvironmentObject private var calls: Calls
    @EnvironmentObject private var flash: Flash

    var body: some View {
        Group {
            if let on = calls.call {
                Talking(on: on)
            } else if let ring = calls.ringing {
                Incoming(ring: ring)
            }
        }
        .interactiveDismissDisabled()
        .toolbar(.hidden, for: .navigationBar)
    }
}

/// Ringing: who is calling and why, with Decline and Answer.
private struct Incoming: View {
    let ring: Ring
    @EnvironmentObject private var calls: Calls
    @EnvironmentObject private var flash: Flash
    @State private var pulse = false

    private var color: Color { flash.spark(ring.spark)?.color ?? .accentColor }

    var body: some View {
        VStack(spacing: 6) {
            Face(name: ring.name, color: color, size: 50)
                .background(
                    Circle()
                        .stroke(color.opacity(pulse ? 0 : 0.7), lineWidth: 3)
                        .scaleEffect(pulse ? 1.6 : 1)
                )
                .onAppear {
                    withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
                }
                .padding(.top, 4)
            Text(ring.name)
                .font(.headline)
                .lineLimit(1)
            Text(ring.reason.isEmpty ? "is calling you" : ring.reason)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            Spacer(minLength: 2)
            HStack(spacing: 28) {
                RoundButton(icon: "phone.down.fill", color: .red, label: "Decline") {
                    calls.decline()
                }
                RoundButton(icon: "phone.fill", color: .green, label: "Answer") {
                    Task { await calls.answer() }
                }
            }
            .padding(.bottom, 2)
        }
        .padding(.horizontal, 6)
    }
}

/// On the call: who, how long, what was said last, the mic and hang up.
private struct Talking: View {
    let on: OnCall
    @EnvironmentObject private var calls: Calls
    @EnvironmentObject private var flash: Flash

    private var color: Color { flash.spark(on.spark)?.color ?? .accentColor }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Face(name: on.name, color: color, size: 26)
                VStack(alignment: .leading, spacing: 0) {
                    Text(on.name).font(.footnote.weight(.semibold)).lineLimit(1)
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(status)
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if !on.said.isEmpty {
                        Text(on.said)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(on.said == "You" ? Color.accentColor : color)
                    }
                    Text(on.caption)
                        .font(.footnote)
                        .foregroundStyle(on.status == .ended ? .secondary : .primary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            if on.status != .ended {
                HStack(spacing: 28) {
                    RoundButton(icon: "phone.down.fill", color: .red, label: "Hang up") {
                        calls.hangUp()
                    }
                    TextFieldLink(prompt: Text("Say something")) {
                        Image(systemName: "mic.fill")
                            .font(.title3)
                            .frame(width: 46, height: 46)
                            .background(Color.accentColor, in: Circle())
                            .foregroundStyle(.black)
                    } onSubmit: { text in
                        calls.talk(text)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Talk")
                    .disabled(on.call.isEmpty)
                }
            }
        }
        .padding(.horizontal, 6)
    }

    private var status: String {
        switch on.status {
        case .ended: return "Call over"
        case .connecting where on.since == nil: return on.incoming ? "Connecting..." : "Calling..."
        default: break
        }
        guard let since = on.since else { return "Calling..." }
        let s = Int(Date().timeIntervalSince(since))
        let clock = "\(s / 60):\(String(format: "%02d", s % 60))"
        switch on.status {
        case .thinking: return "\(clock) · Thinking"
        case .speaking: return "\(clock) · Talking"
        case .listening: return "\(clock) · Your turn"
        default: return clock
        }
    }
}

/// A round call button.
private struct RoundButton: View {
    let icon: String
    let color: Color
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.title3)
                .frame(width: 46, height: 46)
                .background(color, in: Circle())
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
