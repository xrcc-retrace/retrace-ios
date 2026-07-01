//
// LensImageURL.swift
//
// Centralizes the HTTPS URIs we feed into `MWDATDisplay.Image(uri:)` and
// `MWDATDisplay.VideoPlayer(provider: .uri(...))`. The lens loader fetches
// `https` ONLY — plain `http` (e.g. a Bonjour-resolved local server) is
// silently dropped on the glasses, and local file paths / `UIImage`s are
// not supported at all. The backend already serves all the assets we need;
// this utility just builds the URL strings against the active server
// endpoint.
//
// All builders return optional `String?` and guard on an `https://` base
// so that over a plain-http endpoint they return `nil` and renderers fall
// back to text/placeholder instead of handing the lens a URL it will only
// render blank. Once deployed behind the HTTPS cloud endpoint (or a local
// HTTPS tunnel) the real assets load automatically — no toggle.
//

import Foundation

// All builders are `@MainActor` because they read `ServerEndpoint.shared`,
// which is itself `@MainActor`-isolated. Lens renderers run on the main
// actor (LensSession + LensDisplayCoordinator are both `@MainActor`), so
// this is a clean fit — no actor hops needed at the call site.

@MainActor
enum LensImageURL {
  /// JPEG poster for a procedure step's clip — used as the thumbnail
  /// in coaching's `.referenceInline` lens surface (Step 7 adds the
  /// backend route at `GET /api/clips/{id}/step_{n}.jpg`).
  static func clipPosterURL(procedureId: String, stepIndex: Int) -> String? {
    guard !procedureId.isEmpty else { return nil }
    let base = ServerEndpoint.shared.resolvedBaseURL
    guard base.hasPrefix("https://") else { return nil }
    return "\(base)/api/clips/\(procedureId)/step_\(stepIndex).jpg"
  }

  /// Rendered manual-page PNG for manual-sourced procedures. Used in place
  /// of a video clip thumbnail when the step originated from a PDF rather
  /// than a recorded video.
  static func manualImageURL(procedureId: String, stepIndex: Int) -> String? {
    guard !procedureId.isEmpty else { return nil }
    let base = ServerEndpoint.shared.resolvedBaseURL
    guard base.hasPrefix("https://") else { return nil }
    return "\(base)/api/manual_images/\(procedureId)/step_\(stepIndex).png"
  }

  /// Full MP4 URL for full-screen `VideoPlayer` takeover on the lens.
  /// The provider syntax is `VideoPlayer(provider: .uri(thisURL))`.
  static func clipVideoURL(procedureId: String, stepIndex: Int) -> String? {
    guard !procedureId.isEmpty else { return nil }
    let base = ServerEndpoint.shared.resolvedBaseURL
    guard base.hasPrefix("https://") else { return nil }
    return "\(base)/api/clips/\(procedureId)/step_\(stepIndex).mp4"
  }

  /// White-on-transparent "RETRACE" wordmark banner, shown on the lens
  /// navigator Home. Served as a static asset by the backend at
  /// `/static/lens/retrace_banner.png`.
  ///
  /// Returns the URL ONLY when the resolved server is HTTPS — the DAT lens
  /// `Image(uri:)` loader doesn't fetch plain `http`, so over a local http
  /// server this returns nil and the Home tree shows the `Text("RETRACE")`
  /// wordmark instead. Once deployed behind the HTTPS cloud endpoint the
  /// branded image is used automatically (no toggle).
  static func bannerURL() -> String? {
    let base = ServerEndpoint.shared.resolvedBaseURL
    guard base.hasPrefix("https://") else { return nil }
    return "\(base)/static/lens/retrace_banner.png"
  }

  /// Generic upload bucket URL (source videos, etc.). Rarely needed by
  /// the lens directly but kept here for completeness alongside the
  /// clip/manual paths.
  static func uploadURL(filename: String) -> String? {
    guard !filename.isEmpty else { return nil }
    let base = ServerEndpoint.shared.resolvedBaseURL
    guard !base.isEmpty else { return nil }
    return "\(base)/api/uploads/\(filename)"
  }
}
