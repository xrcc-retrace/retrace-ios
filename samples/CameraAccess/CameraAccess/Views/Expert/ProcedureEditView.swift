import SwiftUI
import UIKit

struct ProcedureEditView: View {
  let procedure: ProcedureResponse
  let onSaved: () -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var title: String
  @State private var description: String
  @State private var stepOrder: [ProcedureStepResponse]
  @State private var parts: [EditablePart]
  @State private var isSaving = false
  @State private var errorMessage: String?

  // Reference image (gated behind the feature flag). Changes are *staged*
  // locally via `refIntent` and only committed to the backend on Save, so
  // tapping Cancel reverts them — consistent with the title/step edits.
  @AppStorage("referenceImageEnabled") private var referenceImageEnabled = false
  @State private var refIntent: RefImageIntent = .keep
  @State private var showImageSourceDialog = false

  private let api = ProcedureAPIService()

  init(procedure: ProcedureResponse, onSaved: @escaping () -> Void) {
    self.procedure = procedure
    self.onSaved = onSaved
    self._title = State(initialValue: procedure.title)
    self._description = State(initialValue: procedure.description)
    self._stepOrder = State(initialValue: procedure.steps.sorted { $0.stepNumber < $1.stepNumber })
    self._parts = State(initialValue: (procedure.parts ?? []).map(EditablePart.init))
  }

  private var hasChanges: Bool {
    title != procedure.title ||
    description != procedure.description ||
    stepOrder.map(\.stepNumber) != procedure.steps.sorted(by: { $0.stepNumber < $1.stepNumber }).map(\.stepNumber) ||
    hasPartsChange ||
    (referenceImageEnabled && hasReferenceChange)
  }

  private var hasPartsChange: Bool {
    parts.map(\.asPart) != (procedure.parts ?? [])
  }

  // MARK: - Reference image state

  private var stagedImage: UIImage? {
    if case .replace(let image) = refIntent { return image }
    return nil
  }

  /// True when the original (already-saved) image should be shown — i.e. the
  /// user hasn't staged a replacement or a removal.
  private var showsExistingRemoteImage: Bool {
    if case .keep = refIntent { return procedure.referenceImageUrl != nil }
    return false
  }

  private var hasImageShowing: Bool {
    stagedImage != nil || showsExistingRemoteImage
  }

  private var hasReferenceChange: Bool {
    switch refIntent {
    case .keep: return false
    case .replace, .remove: return true
    }
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

            TextField("Procedure title", text: $title)
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
              .frame(minHeight: 80)
              .padding(Spacing.lg)
              .background(Color.surfaceRaised)
              .cornerRadius(Radius.md)
              .overlay(
                RoundedRectangle(cornerRadius: Radius.md)
                  .stroke(Color.borderSubtle, lineWidth: 1)
              )
          }

          // Parts glossary (staged; committed on Save). What the AI coach
          // uses to visually identify pieces during a Gemini Live session.
          partsSection

          // Reference image (staged; committed on Save)
          if referenceImageEnabled {
            referenceImageSection
          }

          // Step order
          VStack(alignment: .leading, spacing: Spacing.md) {
            Text("STEP ORDER")
              .font(.retraceOverline)
              .tracking(0.5)
              .foregroundColor(.textSecondary)

            ForEach(stepOrder) { step in
              HStack(spacing: Spacing.lg) {
                Image(systemName: "line.3.horizontal")
                  .foregroundColor(.textTertiary)
                  .font(.retraceCallout)

                Text("\(step.stepNumber).")
                  .font(.retraceFace(.semibold, size: 16))
                  .foregroundColor(.textPrimary)

                Text(step.title)
                  .font(.retraceCallout)
                  .foregroundColor(.textPrimary)
                  .lineLimit(1)

                Spacer()
              }
              .padding(Spacing.lg)
              .background(Color.surfaceBase)
              .cornerRadius(Radius.sm)
            }
            .onMove { from, to in
              stepOrder.move(fromOffsets: from, toOffset: to)
            }
          }

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
    .navigationTitle("Edit Workflow")
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
    .referenceImagePicker(isPresented: $showImageSourceDialog) { image in
      refIntent = .replace(image)
    }
  }

  // MARK: - Parts glossary section

  @ViewBuilder
  private var partsSection: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      Text("PARTS")
        .font(.retraceOverline)
        .tracking(0.5)
        .foregroundColor(.textSecondary)

      Text("The AI coach uses these descriptions to visually identify pieces during a session.")
        .font(.retraceSubheadline)
        .foregroundColor(.textTertiary)

      ForEach($parts) { $part in
        VStack(alignment: .leading, spacing: Spacing.md) {
          HStack(spacing: Spacing.lg) {
            TextField("Part name", text: $part.name)
              .font(.retraceFace(.semibold, size: 16))
              .foregroundColor(.textPrimary)

            Button(role: .destructive) {
              parts.removeAll { $0.id == part.id }
            } label: {
              Image(systemName: "trash")
                .font(.retraceCallout)
                .foregroundColor(.semanticError)
            }
          }

          TextEditor(text: $part.appearance)
            .font(.retraceCallout)
            .foregroundColor(.textPrimary)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 60)
        }
        .padding(Spacing.lg)
        .background(Color.surfaceRaised)
        .cornerRadius(Radius.md)
        .overlay(
          RoundedRectangle(cornerRadius: Radius.md)
            .stroke(Color.borderSubtle, lineWidth: 1)
        )
      }

      Button {
        parts.append(EditablePart(name: "", appearance: ""))
      } label: {
        HStack(spacing: Spacing.xs) {
          Image(systemName: "plus.circle")
          Text("Add part")
        }
        .font(.retraceCallout)
        .foregroundColor(.appPrimary)
      }
    }
  }

  // MARK: - Reference image section

  @ViewBuilder
  private var referenceImageSection: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      Text("REFERENCE IMAGE")
        .font(.retraceOverline)
        .tracking(0.5)
        .foregroundColor(.textSecondary)

      referenceImagePreview

      if hasImageShowing {
        HStack(spacing: Spacing.lg) {
          Button {
            showImageSourceDialog = true
          } label: {
            Label("Replace", systemImage: "photo")
              .font(.retraceCallout)
              .foregroundColor(.appPrimary)
          }

          Button(role: .destructive) {
            requestRemove()
          } label: {
            Label("Remove", systemImage: "trash")
              .font(.retraceCallout)
          }

          Spacer(minLength: 0)
        }
      } else {
        Button {
          showImageSourceDialog = true
        } label: {
          HStack(spacing: Spacing.xs) {
            Image(systemName: "photo.badge.plus")
            Text("Add reference image")
          }
          .font(.retraceCallout)
          .foregroundColor(.appPrimary)
        }
      }
    }
  }

  @ViewBuilder
  private var referenceImagePreview: some View {
    if let stagedImage {
      Image(uiImage: stagedImage)
        .resizable()
        .scaledToFill()
        .frame(maxWidth: .infinity)
        .frame(height: 160)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
        .overlay(
          RoundedRectangle(cornerRadius: Radius.md)
            .stroke(Color.borderSubtle, lineWidth: 1)
        )
    } else if showsExistingRemoteImage,
              let urlString = procedure.referenceImageUrl,
              let url = URL(string: "\(api.baseURL)\(urlString)") {
      AsyncImage(url: url) { phase in
        switch phase {
        case .success(let image):
          image.resizable().scaledToFill()
        case .failure:
          referencePlaceholder(text: "Couldn't load image")
        default:
          ZStack {
            Color.surfaceRaised
            ProgressView().tint(.appPrimary)
          }
        }
      }
      .frame(maxWidth: .infinity)
      .frame(height: 160)
      .clipShape(RoundedRectangle(cornerRadius: Radius.md))
      .overlay(
        RoundedRectangle(cornerRadius: Radius.md)
          .stroke(Color.borderSubtle, lineWidth: 1)
      )
    } else {
      referencePlaceholder(text: "No reference image")
    }
  }

  private func referencePlaceholder(text: String) -> some View {
    ZStack {
      RoundedRectangle(cornerRadius: Radius.md)
        .fill(Color.surfaceRaised)
      VStack(spacing: Spacing.sm) {
        Image(systemName: "photo")
          .font(.system(size: 28))
          .foregroundColor(.textTertiary)
        Text(text)
          .font(.retraceSubheadline)
          .foregroundColor(.textTertiary)
      }
    }
    .frame(maxWidth: .infinity)
    .frame(height: 160)
    .overlay(
      RoundedRectangle(cornerRadius: Radius.md)
        .stroke(Color.borderSubtle, lineWidth: 1)
    )
  }

  // MARK: - Reference image actions (staged only — no network until Save)

  private func requestRemove() {
    // If there was a saved image, mark it for removal; otherwise just discard
    // the staged pick (nothing to delete on the server).
    refIntent = procedure.referenceImageUrl != nil ? .remove : .keep
  }

  private func save() async {
    isSaving = true
    errorMessage = nil

    let titleChanged = title != procedure.title
    let descChanged = description != procedure.description
    let orderChanged = stepOrder.map(\.stepNumber) != procedure.steps.sorted(by: { $0.stepNumber < $1.stepNumber }).map(\.stepNumber)
    let partsChanged = hasPartsChange

    do {
      if titleChanged || descChanged || orderChanged || partsChanged {
        // Drop rows with an empty name (a just-added blank card or a
        // cleared-out entry counts as deleted).
        let cleanedParts = parts.map(\.asPart)
          .filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
        let update = ProcedureUpdateRequest(
          title: titleChanged ? title : nil,
          description: descChanged ? description : nil,
          stepOrder: orderChanged ? stepOrder.map(\.stepNumber) : nil,
          parts: partsChanged ? cleanedParts : nil
        )
        _ = try await api.updateProcedure(id: procedure.id, update: update)
      }

      if referenceImageEnabled {
        switch refIntent {
        case .keep:
          break
        case .replace(let image):
          _ = try await api.uploadReferenceImage(procedureId: procedure.id, image: image)
        case .remove:
          try await api.deleteReferenceImage(procedureId: procedure.id)
        }
      }

      onSaved()
      dismiss()
    } catch {
      errorMessage = error.localizedDescription
    }
    isSaving = false
  }
}

/// Staged intent for the reference image while editing. Committed on Save.
private enum RefImageIntent {
  case keep
  case replace(UIImage)
  case remove
}

/// Local editing wrapper for a `ProcedurePart` — gives each row a stable
/// `UUID` identity so `ForEach` bindings survive add/remove, which the
/// server model (keyed only by name/appearance) can't provide while both
/// fields are mid-edit.
private struct EditablePart: Identifiable {
  let id = UUID()
  var name: String
  var appearance: String

  init(name: String, appearance: String) {
    self.name = name
    self.appearance = appearance
  }

  init(_ part: ProcedurePart) {
    self.name = part.name
    self.appearance = part.appearance
  }

  var asPart: ProcedurePart {
    ProcedurePart(name: name, appearance: appearance)
  }
}
