import SwiftUI

/// The answer form for an interactive run parked on an `AskUserQuestion`:
/// each question's header and text, one option button per choice (plus the
/// "Resolve for me" sentinel, honouring `multiSelect`), an "Other" free-text
/// field, and Send. Shared by the plan detail's review/complete panel and the
/// active-runs popover's answer sheet, so a parked question looks and answers
/// the same wherever it is surfaced.
///
/// Selection state is local; key the view with `.id(pending.toolUseId)` so a
/// new question starts fresh. The payload is built by the tested
/// `PlanDetailView.reviewAnswers` (keyed by question text, as the SDK expects).
struct ParkedQuestionForm: View {
    let pending: TaskRun.PendingReviewQuestion
    let onSend: ([String: String]) -> Void

    @State private var selections: [String: [String]] = [:]
    @State private var otherText: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(pending.questions.enumerated()), id: \.offset) { _, question in
                questionView(question)
            }
            HStack {
                Spacer(minLength: 0)
                Button("Send") {
                    onSend(PlanDetailView.reviewAnswers(questions: pending.questions,
                                                        selections: selections,
                                                        otherText: otherText))
                    selections = [:]
                    otherText = [:]
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSend)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.accentColor.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 1)
        )
    }

    /// Send is enabled once at least one question has a pick or "Other" text.
    private var canSend: Bool {
        pending.questions.contains { question in
            let hasPick = !(selections[question.header] ?? []).isEmpty
            let hasOther = !(otherText[question.header] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return hasPick || hasOther
        }
    }

    private func questionView(_ question: ReviewQuestion) -> some View {
        let selected = selections[question.header] ?? []
        let labels = question.options.map(\.label) + [PlanDetailView.resolveForMeLabel]
        return VStack(alignment: .leading, spacing: 8) {
            Text(question.header)
                .font(.subheadline.weight(.semibold))
            Text(question.question)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(labels, id: \.self) { label in
                    let isOn = selected.contains(label)
                    Button {
                        selections[question.header] = PlanDetailView.reviewToggleSelection(
                            current: selected, choice: label, multiSelect: question.multiSelect)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: Self.optionGlyph(isOn: isOn,
                                                               multiSelect: question.multiSelect))
                                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                            Text(label)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 6) {
                Text("Other:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Type a free-text answer…",
                          text: Binding(
                            get: { otherText[question.header] ?? "" },
                            set: { otherText[question.header] = $0 }))
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    /// A checkbox for multi-select, a radio for single-select; filled when on.
    private static func optionGlyph(isOn: Bool, multiSelect: Bool) -> String {
        if multiSelect {
            return isOn ? "checkmark.square.fill" : "square"
        }
        return isOn ? "largecircle.fill.circle" : "circle"
    }
}
