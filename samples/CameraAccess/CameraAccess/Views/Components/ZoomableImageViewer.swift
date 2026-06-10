import SwiftUI

/// Full-screen, pinch-to-zoom image viewer used to expand reference images
/// from the procedure detail. Loads via `CachedAsyncImage` so the bitmap is
/// shared with the inline thumbnail. Pinch + pan compose simultaneously; a
/// downward drag at 1× dismisses, mirroring `PhotoPreviewView`'s feel.
struct ZoomableImageViewer: View {
  let url: URL
  var onClose: () -> Void

  @State private var scale: CGFloat = 1
  @State private var lastScale: CGFloat = 1
  @GestureState private var magnifyBy: CGFloat = 1
  @State private var offset: CGSize = .zero
  @State private var lastOffset: CGSize = .zero

  var body: some View {
    ZStack {
      Color.black
        .ignoresSafeArea()

      imageContent
        .scaleEffect(scale * magnifyBy)
        .offset(offset)
        .gesture(
          SimultaneousGesture(magnification, drag)
        )
        .onTapGesture(count: 2) {
          handleDoubleTap()
        }

      closeButton
    }
  }

  // MARK: - Image

  @ViewBuilder
  private var imageContent: some View {
    CachedAsyncImage(url: url) { phase in
      switch phase {
      case .success(let image):
        image
          .resizable()
          .scaledToFit()
      case .empty:
        ProgressView()
          .progressViewStyle(CircularProgressViewStyle(tint: .white))
      case .failure:
        Image(systemName: "photo")
          .font(.system(size: 44))
          .foregroundColor(.white.opacity(0.5))
      @unknown default:
        Image(systemName: "xmark")
          .font(.system(size: 44))
          .foregroundColor(.white.opacity(0.5))
      }
    }
  }

  // MARK: - Close button

  private var closeButton: some View {
    VStack {
      HStack {
        Spacer()
        Button {
          onClose()
        } label: {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 30))
            .foregroundColor(.white)
            .shadow(color: .black.opacity(0.4), radius: 6, x: 0, y: 2)
        }
        .padding()
      }
      Spacer()
    }
  }

  // MARK: - Gestures

  private var magnification: some Gesture {
    MagnificationGesture()
      .updating($magnifyBy) { value, state, _ in
        state = value
      }
      .onEnded { value in
        let proposed = scale * value
        let clamped = min(max(proposed, 1.0), 5.0)
        if clamped < 1.05 {
          withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            scale = 1
            offset = .zero
            lastOffset = .zero
          }
        } else {
          scale = clamped
        }
        lastScale = scale
      }
  }

  private var drag: some Gesture {
    DragGesture()
      .onChanged { value in
        if scale > 1 {
          offset = CGSize(
            width: lastOffset.width + value.translation.width,
            height: lastOffset.height + value.translation.height
          )
        }
      }
      .onEnded { value in
        if scale > 1 {
          lastOffset = offset
        } else if value.translation.height > 120 {
          onClose()
        }
      }
  }

  private func handleDoubleTap() {
    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
      if scale > 1.05 {
        scale = 1
        offset = .zero
        lastOffset = .zero
      } else {
        scale = 2.5
      }
      lastScale = scale
    }
  }
}
