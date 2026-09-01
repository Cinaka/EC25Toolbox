import SwiftUI

/// Press feedback for the custom circular call controls, which render their
/// own surfaces and therefore miss the native plain-button highlight: a
/// restrained opacity dip plus a small scale cue. Reduce Motion keeps the
/// opacity change only and drops the scale animation.
struct PressableCallButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.95 : 1)
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(
                reduceMotion ? nil : .smooth(duration: 0.14),
                value: configuration.isPressed
            )
    }
}

/// Large circular call action with an iPhone-like label below it.
struct TakeoverActionButton: View {
    var systemImage: String
    var labelKey: String
    var tint: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 9) {
                Image(systemName: systemImage)
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 78, height: 78)
                    .background(tint, in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.16), lineWidth: 1))
                    .shadow(color: tint.opacity(0.25), radius: 14, y: 7)
                Text(localized(labelKey))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
            }
        }
        .buttonStyle(PressableCallButtonStyle())
        .accessibilityLabel(localized(labelKey))
        .help(localized(labelKey))
    }
}

/// Liquid-material call control. Disabled actions remain visible so the
/// control grid never changes geometry as a call advances through phases.
struct TakeoverToggleButton: View {
    var isOn: Bool
    var onImage: String
    var offImage: String
    var onLabelKey: String
    var offLabelKey: String
    var tint: Color
    var disabled = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: isOn ? onImage : offImage)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(isOn ? tint : Color.primary)
                    .frame(width: 72, height: 72)
                    .background(
                        isOn ? tint.opacity(0.18) : Color.primary.opacity(0.075),
                        in: Circle()
                    )
                    .overlay(Circle().stroke(.white.opacity(0.14), lineWidth: 1))
                Text(localized(isOn ? onLabelKey : offLabelKey))
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(width: 104)
        }
        .buttonStyle(PressableCallButtonStyle())
        .opacity(disabled ? 0.38 : 1)
        .disabled(disabled)
        .accessibilityLabel(localized(isOn ? onLabelKey : offLabelKey))
        .help(localized(isOn ? onLabelKey : offLabelKey))
    }
}

struct AudioHealthChip: View {
    var labelKey: String
    var streaming: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(streaming ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 7, height: 7)
            Text(localized(labelKey))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.thinMaterial, in: Capsule())
        .help(localized(streaming
            ? "call.takeover.audio.streaming"
            : "call.takeover.audio.stalled"))
        .accessibilityLabel(localizedFormat(
            "call.takeover.audio.accessibility",
            localized(labelKey),
            localized(streaming
                ? "call.takeover.audio.streaming"
                : "call.takeover.audio.stalled")
        ))
    }
}

struct OverlayCallButton: View {
    var systemImage: String
    var accessibilityLabel: String
    var tint: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(PressableCallButtonStyle())
        .background(tint, in: Circle())
        .help(localized(accessibilityLabel))
        .accessibilityLabel(localized(accessibilityLabel))
    }
}

/// Transparent Liquid Glass action used only by the floating call panel.
/// Ordinary controls stay neutral; answer and hang-up receive their semantic
/// system colors without tinting the entire notification surface.
struct NotificationCallButton: View {
    var systemImage: String
    var accessibilityLabel: String
    var foreground: Color = .primary
    var prominentTint: Color?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(prominentTint == nil ? foreground : Color.white)
                .frame(width: 38, height: 38)
                .contentShape(Circle())
                .modifier(NotificationCallButtonSurface(tint: prominentTint))
        }
        .buttonStyle(PressableCallButtonStyle())
        .help(localized(accessibilityLabel))
        .accessibilityLabel(localized(accessibilityLabel))
    }
}

private struct NotificationCallButtonSurface: ViewModifier {
    var tint: Color?

    func body(content: Content) -> some View {
        if let tint {
            content
                .background(tint, in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
                .shadow(color: tint.opacity(0.2), radius: 8, y: 4)
        } else {
            content
                .glassEffect(.regular.interactive(), in: .circle)
        }
    }
}
