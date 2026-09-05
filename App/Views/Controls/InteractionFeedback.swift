import AppKit
import SwiftUI

private struct PressFeedbackModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var isPressed = false

    func body(content: Content) -> some View {
        content
            .opacity(isPressed ? 0.72 : 1)
            .brightness(isPressed ? -0.06 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: isPressed)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .updating($isPressed) { _, state, _ in
                        state = true
                    }
            )
    }
}

extension View {
    /// Makes the mouse-down state of a control unmistakable while preserving its
    /// native button style, keyboard behavior, and action semantics.
    func pressFeedback() -> some View {
        modifier(PressFeedbackModifier())
    }
}

struct NavigationRowButtonStyle: ButtonStyle {
    let isSelected: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Color.accentColor.opacity(backgroundOpacity(isPressed: configuration.isPressed)),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.10),
                value: configuration.isPressed
            )
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.12),
                value: isSelected
            )
    }

    private func backgroundOpacity(isPressed: Bool) -> Double {
        if isSelected {
            return isPressed ? 0.24 : 0.18
        }
        return isPressed ? 0.10 : 0
    }
}

struct CopyConfirmationButton: View {
    let value: String
    var title = "Copy"
    var helpText = "Copy"
    var width: CGFloat = 96

    @State private var isCopied = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Button(action: copy) {
            Label(displayTitle, systemImage: systemImage)
                .lineLimit(1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .foregroundStyle(isCopied ? Color.green : Color.primary)
                .contentTransition(.symbolEffect(.replace))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: width, height: 36)
        .background(isCopied ? Color.green.opacity(0.12) : Color.secondary.opacity(0.10))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.secondary.opacity(0.10))
                .frame(width: 1)
        }
        .pressFeedback()
        .help(isCopied ? "Copied" : helpText)
        .accessibilityLabel(isCopied ? "Copied" : title)
        .onDisappear {
            resetTask?.cancel()
            resetTask = nil
        }
    }

    private var displayTitle: String {
        isCopied ? "Copied" : title
    }

    private var systemImage: String {
        isCopied ? "checkmark" : "doc.on.doc"
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)

        resetTask?.cancel()
        isCopied = true
        resetTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(1.5))
            } catch {
                return
            }
            isCopied = false
            resetTask = nil
        }
    }
}
