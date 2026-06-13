//
//  GlassChrome.swift
//  EarShot
//

import SwiftUI

/// Wraps a chrome surface (status strip, toolbar, header band) in the
/// macOS 26 Liquid Glass material via `.glassEffect(in:)`.
///
/// Falls back to an opaque `windowBackgroundColor` fill when the user has
/// Reduce Transparency enabled in System Settings → Accessibility — the
/// system contract is that backgrounds must be opaque under that
/// preference.
struct ChromeSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
            )
        } else if #available(macOS 26.0, *) {
            content.glassEffect(in: .rect(cornerRadius: cornerRadius))
        } else {
            content.background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.thinMaterial)
            )
        }
    }
}

/// Solid, high-contrast surface for the transcript reading area. NEVER
/// uses glass: text legibility wins over chrome consistency here. Pulls
/// `textBackgroundColor` so the surface tracks light/dark mode and the
/// system increase-contrast setting.
struct TranscriptReadingSurface: ViewModifier {
    let cornerRadius: CGFloat
    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
    }
}

extension View {
    /// Apply macOS 26 Liquid Glass to a chrome surface. Honors Reduce
    /// Transparency by falling back to an opaque window-background fill.
    func chromeSurface(cornerRadius: CGFloat = 12) -> some View {
        modifier(ChromeSurface(cornerRadius: cornerRadius))
    }

    /// Solid background for the transcript reading area. Never glass.
    func transcriptReadingSurface(cornerRadius: CGFloat = 10) -> some View {
        modifier(TranscriptReadingSurface(cornerRadius: cornerRadius))
    }
}
