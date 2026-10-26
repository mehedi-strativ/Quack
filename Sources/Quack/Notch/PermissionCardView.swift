import SwiftUI
import QuackKit

/// A request a Claude Code session is waiting on, answered in place with the
/// same choices Claude Code offers: a question's options (plus your own
/// answer), or a tool permission's Yes / "Yes, and don't ask again..." / No.
struct PermissionCardView: View {
    let prompt: PermissionPrompt
    let project: String
    /// Other requests queued behind this one.
    let moreCount: Int
    let onAnswer: (PermissionDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let questions = prompt.questions, !questions.isEmpty {
                QuestionsForm(questions: questions) { onAnswer(.answer($0)) }
            } else {
                PermissionOptions(prompt: prompt, onAnswer: onAnswer)
            }
            HStack {
                if moreCount > 0 {
                    Text("+\(moreCount) more waiting")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(NotchTheme.orangeSoft)
                }
                Spacer(minLength: 0)
                Button("Answer in terminal") { onAnswer(.ask) }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(NotchTheme.textMuted)
                    .help("Stop waiting here and show Claude Code's own prompt")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(NotchTheme.card))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(NotchTheme.orange.opacity(0.5), lineWidth: 1))
    }

    private var isQuestion: Bool { !(prompt.questions ?? []).isEmpty }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: isQuestion ? "questionmark.bubble.fill" : "exclamationmark.shield.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(NotchTheme.orange)
            Text(project)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(NotchTheme.textPrimary).lineLimit(1)
            Text(isQuestion ? "has a question" : "wants to use \(prompt.tool_name)")
                .font(.system(size: 11)).foregroundStyle(NotchTheme.textSecondary).lineLimit(1)
            Spacer(minLength: 0)
        }
    }
}

/// Tool permission: what will run, then Claude Code's numbered choices.
private struct PermissionOptions: View {
    let prompt: PermissionPrompt
    let onAnswer: (PermissionDecision) -> Void
    @State private var feedback = ""
    @State private var showsFeedback = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let summary = prompt.summary {
                Text(summary)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(NotchTheme.textPrimary)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 4)
                    .help(summary)
            }
            ForEach(Array(prompt.options.enumerated()), id: \.offset) { i, option in
                OptionRow(number: i + 1, label: option.label, detail: nil,
                          selected: false, tint: rowTint(option.decision)) {
                    if case .deny = option.decision { showsFeedback = true } else { onAnswer(option.decision) }
                }
            }
            if showsFeedback {
                FeedbackField(text: $feedback, placeholder: "Tell Claude what to do instead (optional)",
                              submitTitle: "Deny") {
                    onAnswer(.deny(message: feedback.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }
        }
    }

    private func rowTint(_ d: PermissionDecision) -> Color {
        if case .deny = d { return NotchTheme.textSecondary }
        return NotchTheme.green
    }
}

/// AskUserQuestion, one question at a time like Claude Code: a tab per
/// question (checked once answered), its options plus "Other…", and Submit
/// once every question has an answer. A single single-select question
/// answers on click.
private struct QuestionsForm: View {
    let questions: [AskQuestion]
    let onSubmit: ([String: String]) -> Void
    @State private var current = 0
    @State private var picks: [String: [String]] = [:]
    @State private var other: [String: String] = [:]
    @State private var editingOther: Set<String> = []

    private var answersOnClick: Bool { questions.count == 1 && questions[0].multiSelect != true }

    var body: some View {
        let q = questions[min(current, questions.count - 1)]
        VStack(alignment: .leading, spacing: 6) {
            if questions.count > 1 { tabs }
            Text(q.question)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(NotchTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 2)
            ForEach(Array(q.options.enumerated()), id: \.offset) { i, option in
                OptionRow(number: i + 1, label: option.label, detail: option.description,
                          selected: picks[q.question, default: []].contains(option.label),
                          tint: NotchTheme.green) {
                    pick(option.label, in: q)
                }
            }
            OptionRow(number: q.options.count + 1, label: "Other…", detail: nil,
                      selected: editingOther.contains(q.question), tint: NotchTheme.textSecondary) {
                editingOther.insert(q.question)
                if q.multiSelect != true { picks[q.question] = [] }
            }
            if editingOther.contains(q.question) {
                FeedbackField(text: Binding(get: { other[q.question, default: ""] },
                                            set: { other[q.question] = $0 }),
                              placeholder: "Your answer", submitTitle: answersOnClick ? "Send" : nil) {
                    answersOnClick ? submit() : advance()
                }
            }
            if !answersOnClick {
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    if q.multiSelect == true, current < questions.count - 1 {
                        pillButton("Next", enabled: answers[q.question] != nil, filled: false) { advance() }
                    }
                    pillButton("Submit", enabled: isComplete, filled: true, action: submit)
                }
                .padding(.top, 2)
            }
        }
    }

    /// One chip per question: current one highlighted, answered ones checked.
    private var tabs: some View {
        HStack(spacing: 4) {
            ForEach(Array(questions.enumerated()), id: \.offset) { i, q in
                let done = answers[q.question] != nil
                Button { current = i } label: {
                    HStack(spacing: 3) {
                        if done { Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)) }
                        Text((q.header?.isEmpty == false ? q.header! : "Q\(i + 1)").uppercased())
                            .font(.system(size: 9, weight: .bold)).lineLimit(1)
                    }
                    .foregroundStyle(i == current ? Color.black : (done ? NotchTheme.green : NotchTheme.textSecondary))
                    .padding(.horizontal, 7).frame(height: 18)
                    .background(Capsule().fill(i == current ? NotchTheme.orangeSoft : Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    private func pillButton(_ title: String, enabled: Bool, filled: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(filled ? Color.black : NotchTheme.textPrimary)
                .padding(.horizontal, 14).frame(height: 24)
                .background(Capsule().fill(filled ? (enabled ? NotchTheme.green : NotchTheme.textMuted)
                                                  : Color.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func pick(_ label: String, in q: AskQuestion) {
        if q.multiSelect == true {
            var set = picks[q.question, default: []]
            if let i = set.firstIndex(of: label) { set.remove(at: i) } else { set.append(label) }
            picks[q.question] = set
        } else {
            picks[q.question] = [label]
            editingOther.remove(q.question)
            answersOnClick ? submit() : advance()
        }
    }

    /// Next unanswered question after the current one (wrapping), if any.
    private func advance() {
        let n = questions.count
        for step in 1..<max(n, 1) {
            let i = (current + step) % n
            if answers[questions[i].question] == nil { current = i; return }
        }
    }

    /// Picked labels (in option order) plus any typed text, per question.
    private var answers: [String: String] {
        var out: [String: String] = [:]
        for q in questions {
            let chosen = q.options.map(\.label).filter { picks[q.question, default: []].contains($0) }
            let typed = editingOther.contains(q.question)
                ? other[q.question, default: ""].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            let parts = chosen + (typed.isEmpty ? [] : [typed])
            if !parts.isEmpty { out[q.question] = parts.joined(separator: ", ") }
        }
        return out
    }

    private var isComplete: Bool { answers.count == questions.count }

    private func submit() {
        guard isComplete else { return }
        onSubmit(answers)
    }
}

/// One numbered choice, styled like Claude Code's prompt list.
private struct OptionRow: View {
    let number: Int
    let label: String
    let detail: String?
    let selected: Bool
    let tint: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(number).")
                    .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(selected ? tint : NotchTheme.textMuted)
                    .frame(width: 16, alignment: .trailing)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selected ? tint : NotchTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 10))
                            .foregroundStyle(NotchTheme.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(tint)
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(selected ? tint.opacity(0.14) : (hovering ? Color.white.opacity(0.07) : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A one-line text input (the panel takes keyboard focus only while you type
/// here) with an optional submit button; Return submits too.
private struct FeedbackField: View {
    @Binding var text: String
    let placeholder: String
    let submitTitle: String?
    let onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(NotchTheme.textPrimary)
                .padding(.horizontal, 8).frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
                .onSubmit(onSubmit)
            if let submitTitle {
                Button(action: onSubmit) {
                    Text(submitTitle)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(NotchTheme.textPrimary)
                        .padding(.horizontal, 12).frame(height: 26)
                        .background(Capsule().fill(Color.white.opacity(0.14)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 24)
    }
}
