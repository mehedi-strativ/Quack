import SwiftUI
import QuackKit

/// A held Claude Code permission request: what the tool wants to do, and
/// Allow / Deny / hand back to the terminal.
struct PermissionCardView: View {
    let prompt: PermissionPrompt
    let project: String
    let onAnswer: (PermissionDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(NotchTheme.orange)
                Text(project)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(NotchTheme.textPrimary).lineLimit(1)
                Text("wants to use \(prompt.tool_name)")
                    .font(.system(size: 11)).foregroundStyle(NotchTheme.textSecondary).lineLimit(1)
                Spacer(minLength: 0)
            }
            Text(prompt.summary ?? prompt.tool_name)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(NotchTheme.textPrimary)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
                .help(prompt.summary ?? "")
            HStack(spacing: 6) {
                button("Allow", fg: .black, bg: NotchTheme.green) { onAnswer(.allow) }
                button("Deny", fg: NotchTheme.textPrimary, bg: Color.white.opacity(0.12)) { onAnswer(.deny) }
                Spacer(minLength: 0)
                button("Terminal", fg: NotchTheme.textSecondary, bg: .clear) { onAnswer(.ask) }
                    .help("Answer in Claude Code instead")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(NotchTheme.card))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(NotchTheme.orange.opacity(0.5), lineWidth: 1))
    }

    private func button(_ title: String, fg: Color, bg: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(fg)
                .padding(.horizontal, 12).frame(height: 24)
                .background(Capsule().fill(bg))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
