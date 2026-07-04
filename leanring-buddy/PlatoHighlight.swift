// MARK: - Plato
//
//  PlatoHighlight.swift
//  leanring-buddy
//
//  The data model for one on-screen teaching highlight. Anchored in GLOBAL
//  AppKit coordinates (bottom-left origin) — the same space as displayFrame and
//  NSEvent.mouseLocation — so the overlay can convert it per screen. Highlights
//  are always momentary (see timeToLive); absolute-coordinate boxes go stale the
//  instant the user scrolls.
//

import SwiftUI

struct PlatoHighlight: Identifiable {
    enum ArrowDirection {
        case up, down, left, right
    }

    enum Kind {
        /// Translucent shaded rectangle — "study / include this area of the paper".
        case filledRegion(color: Color)
        /// Crisp ring with no fill — a tight outline around an app control.
        case strokedRegion(color: Color, lineWidth: CGFloat)
        /// Expanding "click here" pulse centered on the rect.
        case ripplePulse(color: Color)
        /// A directional affordance — "scroll down to the section".
        case directionalArrow(direction: ArrowDirection, color: Color)
        /// Dim the whole screen except this rect, to focus attention.
        case spotlight(dimOpacity: CGFloat)
    }

    let id = UUID()
    let kind: Kind
    /// GLOBAL AppKit frame (bottom-left origin), same space as displayFrame.
    let globalFrame: CGRect
    let label: String?
    let createdAt: Date
    /// Auto-expiry. Always finite — never persistent. Recommend 3–5s.
    let timeToLive: TimeInterval

    /// Whether this highlight's time-to-live has elapsed at `date`.
    /// Pure so the pruner's expiry rule is unit-testable.
    func isExpired(at date: Date) -> Bool {
        date.timeIntervalSince(createdAt) > timeToLive
    }

    /// Maps the model's color name to an intentional, legible highlight color.
    /// Colors are paired with an outline + label by the views, never hue alone,
    /// so red/green remain distinguishable for color-blind users.
    static func color(forName colorName: String?) -> Color {
        switch (colorName ?? "blue").lowercased() {
        case "red":    return Color(hex: "#FF3B30")
        case "green":  return Color(hex: "#34C759")
        case "yellow": return Color(hex: "#FFD60A")
        case "blue":   return Color(hex: "#0A84FF")
        default:       return Color(hex: "#0A84FF")
        }
    }
}
