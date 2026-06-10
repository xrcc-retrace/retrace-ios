import SwiftUI
import UIKit

extension View {
  /// Presents a "Take Photo / Choose from Library" chooser, then the system
  /// image picker, decoding the picked file to a `UIImage`. The camera option
  /// is hidden when unavailable. Shared by the expert reference-image flows
  /// (`ProcedureReviewView` eager upload, `ProcedureEditView` staged commit).
  func referenceImagePicker(
    isPresented: Binding<Bool>,
    onPick: @escaping (UIImage) -> Void
  ) -> some View {
    modifier(ReferenceImagePickerModifier(isPresented: isPresented, onPick: onPick))
  }
}

private struct ReferenceImagePickerModifier: ViewModifier {
  @Binding var isPresented: Bool
  let onPick: (UIImage) -> Void

  @State private var showPicker = false
  @State private var source: UIImagePickerController.SourceType = .photoLibrary

  func body(content: Content) -> some View {
    content
      .confirmationDialog(
        "Reference image",
        isPresented: $isPresented,
        titleVisibility: .visible
      ) {
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
          Button("Take Photo") {
            source = .camera
            showPicker = true
          }
        }
        Button("Choose from Library") {
          source = .photoLibrary
          showPicker = true
        }
        Button("Cancel", role: .cancel) {}
      }
      .sheet(isPresented: $showPicker) {
        MediaPickerView(mode: .image, source: source) { url, _ in
          showPicker = false
          if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
            onPick(image)
          }
        }
      }
  }
}
