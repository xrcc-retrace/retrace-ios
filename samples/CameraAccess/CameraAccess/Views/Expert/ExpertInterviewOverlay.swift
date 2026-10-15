import SwiftUI

// Phone-side chrome for the Expert Interviewer. Lives in the recording
// view's `chrome:` layer (outside the lens square), so it follows the app's
// glass-panel language rather than the Ray-Ban HUD rules. The lens-side
// question card is a follow-up (see docs/expert-interviewer-design.md §4.9).

// MARK: - Pre-record mode picker

/// Three-way pill shown before recording starts. Changing it after
/// `prepare()` has run has no effect on the current session — the audio
/// mode is chosen when the recording screen opens — so the picker is
/// disabled once the interviewer has been constructed for this session.
struct ExpertInterviewerModePicker: View {
  @Binding var mode: InterviewerMode
  let isLocked: Bool

  var body: some View {
    HStack(spacing: 4) {
      ForEach(InterviewerMode.allCases) { m in
        Button {
          guard !isLocked else { return }
          mode = m
        } label: {
          HStack(spacing: 6) {
            Image(systemName: m.iconName)
              .font(.system(size: 12, weight: .semibold))
            Text(m.label)
              .font(.retraceCaption1)
          }
          .foregroundColor(mode == m ? .textPrimary : .textSecondary)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .background(
            RoundedRectangle(cornerRadius: Radius.full, style: .continuous)
              .fill(mode == m ? Color.surfaceRaised : Color.clear)
          )
        }
        .buttonStyle(.plain)
      }
    }
    .padding(4)
    .glassPanel(cornerRadius: Radius.full)
    .opacity(isLocked ? 0.6 : 1)
    .accessibilityLabel("Interviewer mode")
  }
}

// MARK: - Recording-time status + question card

struct ExpertInterviewStatusPill: View {
  @ObservedObject var interviewer: ExpertInterviewViewModel

  private var text: String {
    if !interviewer.isInterviewerAvailable { return "Interviewer unavailable" }
    switch interviewer.geminiConnectionState {
    case .connecting: return "Interviewer connecting…"
    case .error: return "Interviewer reconnecting…"
    case .disconnected: return "Interviewer off"
    case .connected:
      if interviewer.isListeningForAnswer { return "Listening for your answer" }
      if interviewer.isAISpeaking { return "Asking…" }
      if interviewer.quietMode { return "Holding questions for the end" }
      return interviewer.mode == .quiet ? "Taking notes · debrief after" : "Taking notes"
    }
  }

  private var dotColor: Color {
    if !interviewer.isInterviewerAvailable { return .textTertiary }
    if interviewer.isListeningForAnswer { return Color(red: 0.36, green: 0.84, blue: 0.56) }
    if interviewer.isAISpeaking { return Color(red: 0.55, green: 0.70, blue: 1.0) }
    return .textTertiary
  }

  var body: some View {
    HStack(spacing: 8) {
      Circle()
        .fill(dotColor)
        .frame(width: 8, height: 8)
      Text(text)
        .font(.retraceCaption1)
        .foregroundColor(.textSecondary)
        .lineLimit(1)
      if interviewer.openGaps > 0 || interviewer.answeredCount > 0 {
        Text("· \(interviewer.answeredCount) noted")
          .font(.retraceCaption1)
          .foregroundColor(.textTertiary)
          .monospacedDigit()
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .glassPanel(cornerRadius: Radius.full)
    .animation(.easeInOut(duration: 0.2), value: text)
  }
}

struct ExpertInterviewQuestionCard: View {
  let question: String
  let isListening: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        Image(systemName: isListening ? "waveform" : "text.bubble")
          .font(.system(size: 12, weight: .semibold))
          .symbolEffect(.variableColor.iterative, isActive: isListening)
        Text(isListening ? "Listening — answer when ready" : "Interviewer")
          .font(.retraceCaption1)
      }
      .foregroundColor(.textSecondary)
      Text(question)
        .font(.retraceHeadline)
        .foregroundColor(.textPrimary)
        .fixedSize(horizontal: false, vertical: true)
      Text("Say “later” to defer or “skip” to drop it.")
        .font(.retraceCaption1)
        .foregroundColor(.textTertiary)
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .glassPanel(cornerRadius: Radius.lg)
  }
}

// MARK: - Debrief overlay

struct ExpertInterviewDebriefOverlay: View {
  @ObservedObject var interviewer: ExpertInterviewViewModel
  let onDone: () -> Void

  var body: some View {
    ZStack {
      Color.black.opacity(0.55).ignoresSafeArea()
      VStack(spacing: Spacing.lg) {
        VStack(spacing: 6) {
          Text("Quick debrief")
            .font(.retraceTitle1)
            .foregroundColor(.textPrimary)
          Text(interviewer.debriefQuestions.isEmpty
               ? "Wrapping up your notes…"
               : "A few things a learner would need. Answer out loud, or say “done”.")
            .font(.retraceSubheadline)
            .foregroundColor(.textSecondary)
            .multilineTextAlignment(.center)
        }

        if interviewer.phase == .finalized || interviewer.debriefQuestions.isEmpty {
          ProgressView().tint(.textPrimary)
        } else {
          VStack(alignment: .leading, spacing: 10) {
            ForEach(interviewer.debriefQuestions) { q in
              HStack(alignment: .top, spacing: 10) {
                Image(systemName: interviewer.debriefAnsweredIds.contains(q.questionId)
                      ? "checkmark.circle.fill"
                      : (interviewer.currentQuestion == q.question ? "waveform.circle" : "circle"))
                  .foregroundColor(interviewer.debriefAnsweredIds.contains(q.questionId) ? .textPrimary : .textTertiary)
                  .font(.system(size: 18))
                Text(q.question)
                  .font(.retraceSubheadline)
                  .foregroundColor(interviewer.currentQuestion == q.question ? .textPrimary : .textSecondary)
                  .fixedSize(horizontal: false, vertical: true)
              }
            }
          }
          .padding(16)
          .frame(maxWidth: .infinity, alignment: .leading)
          .glassPanel(cornerRadius: Radius.lg)
        }

        CustomButton(
          title: interviewer.phase == .finalized ? "Finishing…" : "Done",
          style: .primary,
          isDisabled: interviewer.phase == .finalized,
          action: onDone
        )
      }
      .padding(24)
      .frame(maxWidth: 480)
    }
    .transition(.opacity)
  }
}
