import SwiftUI

struct StepEditView: View {
  let procedureId: String
  let step: ProcedureStepResponse
  let localSaveHandler: ((ProcedureStepResponse) -> Void)?
  let onSaved: () -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var title: String
  @State private var description: String
  @State private var displaySummary: String
  @State private var tips: [String]
  @State private var warnings: [String]
  @State private var errorCriteria: [String]
  @State private var isSaving = false
  @State private var errorMessage: String?

  private let api = ProcedureAPIService()

  init(
    procedureId: String,
    step: ProcedureStepResponse,
    localSaveHandler: ((ProcedureStepResponse) -> Void)? = nil,
    onSaved: @escaping () -> Void = {}
  ) {
    self.procedureId = procedureId
    self.step = step
    self.localSaveHandler = localSaveHandler
    self.onSaved = onSaved
    self._title = State(initialValue: step.title)
    self._description = State(initialValue: step.description)
    self._displaySummary = State(initialValue: step.displaySummary ?? "")
    self._tips = State(initialValue: step.tips)
    self._warnings = State(initialValue: step.warnings)
    self._errorCriteria = State(initialValue: step.errorCriteria)
  }

  private var hasChanges: Bool {
    title != step.title ||
    description != step.description ||
    displaySummary != (step.displaySummary ?? "") ||
    tips != step.tips ||
    warnings != step.warnings ||
    errorCriteria != step.errorCriteria
  }

  var body: some View {
    RetraceScreen {

      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.screenPadding) {
          // Title
          VStack(alignment: .leading, spacing: Spacing.md) {
            Text("TITLE")
              .font(.retraceOverline)
              .tracking(0.5)
              .foregroundColor(.textSecondary)

            TextField("Step title", text: $title)
              .font(.retraceHeadline)
              .foregroundColor(.textPrimary)
              .padding(Spacing.lg)
              .background(Color.surfaceRaised)
              .cornerRadius(Radius.md)
              .overlay(
                RoundedRectangle(cornerRadius: Radius.md)
                  .stroke(Color.borderSubtle, lineWidth: 1)
              )
          }

          // Description
          VStack(alignment: .leading, spacing: Spacing.md) {
            Text("DESCRIPTION")
              .font(.retraceOverline)
              .tracking(0.5)
              .foregroundColor(.textSecondary)

            TextEditor(text: $description)
              .font(.retraceCallout)
              .foregroundColor(.textPrimary)
              .scrollContentBackground(.hidden)
              .frame(minHeight: 100)
              .padding(Spacing.lg)
              .background(Color.surfaceRaised)
              .cornerRadius(Radius.md)
              .overlay(
                RoundedRectangle(cornerRadius: Radius.md)
                  .stroke(Color.borderSubtle, lineWidth: 1)
              )
          }

          // Lens summary — the condensed text the glasses lens card shows in
          // place of the full description (Gemini Live still speaks the full
          // description). Empty = lens falls back to the description.
          VStack(alignment: .leading, spacing: Spacing.md) {
            HStack {
              Text("LENS SUMMARY")
                .font(.retraceOverline)
                .tracking(0.5)
                .foregroundColor(.textSecondary)
              Spacer()
              Text("\(displaySummary.count)/160")
                .font(.retraceCaption1)
                .foregroundColor(displaySummary.count > 160 ? .semanticError : .textTertiary)
            }

            Text("Short version shown on the glasses display. Leave empty to show the description.")
              .font(.retraceCaption1)
              .foregroundColor(.textTertiary)

            TextEditor(text: $displaySummary)
              .font(.retraceCallout)
              .foregroundColor(.textPrimary)
              .scrollContentBackground(.hidden)
              .frame(minHeight: 60)
              .padding(Spacing.lg)
              .background(Color.surfaceRaised)
              .cornerRadius(Radius.md)
              .overlay(
                RoundedRectangle(cornerRadius: Radius.md)
                  .stroke(Color.borderSubtle, lineWidth: 1)
              )
          }

          // Clip preview (video) or reference image (manual-derived step)
          if let clipUrl = step.clipUrl,
             let url = URL(string: "\(api.baseURL)\(clipUrl)") {
            let isImage = ["png", "jpg", "jpeg"].contains(url.pathExtension.lowercased())
            VStack(alignment: .leading, spacing: Spacing.md) {
              Text(isImage ? "REFERENCE IMAGE" : "CLIP PREVIEW")
                .font(.retraceOverline)
                .tracking(0.5)
                .foregroundColor(.textSecondary)
              if isImage {
                CachedAsyncImage(url: url) { phase in
                  switch phase {
                  case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fit)
                  case .failure:
                    Color.surfaceRaised.overlay(
                      Image(systemName: "doc.fill")
                        .foregroundColor(.textSecondary)
                    )
                  case .empty:
                    Color.surfaceRaised.overlay(ProgressView())
                  @unknown default:
                    Color.surfaceRaised
                  }
                }
                .frame(maxWidth: .infinity)
                .cornerRadius(Radius.md)
              } else {
                StepClipPlayer(url: url)
              }
            }
          }

          // Timestamps
          VStack(alignment: .leading, spacing: Spacing.md) {
            Text("TIMESTAMPS")
              .font(.retraceOverline)
              .tracking(0.5)
              .foregroundColor(.textSecondary)

            HStack(spacing: Spacing.xl) {
              InfoItem(label: "Start", value: formatTimestamp(step.timestampStart))
              InfoItem(label: "End", value: formatTimestamp(step.timestampEnd))
            }
          }

          // Tips
          EditableStringList(
            title: "Tips",
            items: $tips,
            accentColor: .semanticInfo,
            placeholder: "Enter a tip"
          )

          // Warnings
          EditableStringList(
            title: "Warnings",
            items: $warnings,
            accentColor: .appPrimary,
            placeholder: "Enter a warning"
          )

          // Red Flags (what the AI coach watches for to interject)
          EditableStringList(
            title: "Red Flags",
            items: $errorCriteria,
            accentColor: .appPrimary,
            placeholder: "Describe a visible mistake the coach should catch"
          )

          // Visual verifiability (read-only) — how reliably the server-side
          // oracle can confirm this step's end-state from the camera and
          // auto-advance. Set at extraction time; not editable here.
          HStack(spacing: Spacing.sm) {
            Image(systemName: "eye")
              .font(.system(size: 11, weight: .semibold))
            Text("Auto-advance: \(verifiabilityLabel)")
              .font(.retraceCaption1)
          }
          .foregroundColor(.textSecondary)
          .padding(.horizontal, Spacing.md)
          .padding(.vertical, Spacing.sm)
          .background(Color.surfaceRaised)
          .clipShape(Capsule())

          // Error
          if let error = errorMessage {
            Text(error)
              .font(.retraceSubheadline)
              .foregroundColor(.semanticError)
          }
        }
        .padding(Spacing.screenPadding)
      }
    }
    .navigationTitle("Edit Step \(step.stepNumber)")
    .navigationBarTitleDisplayMode(.inline)
    .retraceNavBar()
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Button("Cancel") { dismiss() }
          .foregroundColor(.textPrimary)
      }
      ToolbarItem(placement: .topBarTrailing) {
        Button("Save") {
          Task { await save() }
        }
        .foregroundColor(hasChanges ? .textPrimary : .textTertiary)
        .disabled(!hasChanges || isSaving)
      }
    }
  }

  private func save() async {
    isSaving = true
    errorMessage = nil

    let cleanSummary = displaySummary.trimmingCharacters(in: .whitespacesAndNewlines)
    let cleanTips = tips.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    let cleanWarnings = warnings.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    let cleanErrorCriteria = errorCriteria.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

    if let localSaveHandler {
      // Review-stage path: merge edits into the parent's local state, no API call.
      // Server commit is deferred to the review screen's Confirm button.
      let updated = ProcedureStepResponse(
        stepNumber: step.stepNumber,
        title: title,
        description: description,
        timestampStart: step.timestampStart,
        timestampEnd: step.timestampEnd,
        tips: cleanTips,
        warnings: cleanWarnings,
        displaySummary: cleanSummary.isEmpty ? nil : cleanSummary,
        errorCriteria: cleanErrorCriteria,
        clipUrl: step.clipUrl,
        visualVerifiability: step.visualVerifiability
      )
      // Dismiss before propagating the merge. If we mutate the parent's
      // `steps` array first, the parent re-renders and the NavigationLink
      // destination's identity churns — `dismiss()` then no-ops because
      // the pop target has shifted out from under us. (Cancel works
      // today because it does nothing but dismiss.) Closures captured by
      // value survive the dismiss, so calling localSaveHandler after
      // pop is safe.
      isSaving = false
      dismiss()
      localSaveHandler(updated)
      return
    }

    let update = StepUpdateRequest(
      title: title != step.title ? title : nil,
      description: description != step.description ? description : nil,
      tips: cleanTips != step.tips ? cleanTips : nil,
      warnings: cleanWarnings != step.warnings ? cleanWarnings : nil,
      errorCriteria: cleanErrorCriteria != step.errorCriteria ? cleanErrorCriteria : nil,
      displaySummary: cleanSummary != (step.displaySummary ?? "") ? cleanSummary : nil
    )

    do {
      _ = try await api.updateStep(procedureId: procedureId, stepNumber: step.stepNumber, update: update)
      // Same dismiss-first pattern as the localSaveHandler path:
      // onSaved() typically triggers a parent refetch that re-renders
      // the NavigationLink chain and can race with dismiss.
      isSaving = false
      dismiss()
      onSaved()
      return
    } catch {
      errorMessage = error.localizedDescription
    }
    isSaving = false
  }

  /// Human-readable label for `visualVerifiability`. Maps the server's
  /// `none` to "Verbal-only"; otherwise capitalizes the raw value
  /// ("reliable" → "Reliable", "marginal" → "Marginal").
  private var verifiabilityLabel: String {
    switch step.visualVerifiability.lowercased() {
    case "none": return "Verbal-only"
    default: return step.visualVerifiability.capitalized
    }
  }

  private func formatTimestamp(_ seconds: Double) -> String {
    let mins = Int(seconds) / 60
    let secs = Int(seconds) % 60
    return String(format: "%d:%02d", mins, secs)
  }
}
