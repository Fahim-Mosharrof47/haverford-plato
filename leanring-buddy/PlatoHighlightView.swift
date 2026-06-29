// MARK: - Plato
//
//  PlatoHighlightView.swift
//  leanring-buddy
//
//  Renders one PlatoHighlight inside the existing click-through overlay window.
//  Because the host NSWindow is full-screen and ignoresMouseEvents, nothing here
//  can intercept input — every shape is purely visual. Coordinates arrive in
//  GLOBAL AppKit space and are converted to overlay-local SwiftUI space here.
//

import SwiftUI

struct PlatoHighlightView: View {
    let highlight: PlatoHighlight
    /// This overlay window's screen frame, in global AppKit coordinates.
    let screenFrame: CGRect

    @State private var rippleProgress: CGFloat = 0

    var body: some View {
        let localRect = HighlightGeometry.localRectFromGlobalRect(highlight.globalFrame, screenFrame: screenFrame)

        Group {
            switch highlight.kind {
            case .filledRegion(let color):
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(color.opacity(0.28))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(color.opacity(0.95), lineWidth: 2)
                    )
                    .frame(width: localRect.width, height: localRect.height)
                    .position(x: localRect.midX, y: localRect.midY)

            case .strokedRegion(let color, let lineWidth):
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(color, lineWidth: lineWidth)
                    .frame(width: localRect.width, height: localRect.height)
                    .position(x: localRect.midX, y: localRect.midY)

            case .ripplePulse(let color):
                // Expanding "click here" pulse. A repeating SwiftUI animation
                // loops cleanly and auto-stops when the view leaves the tree on TTL.
                Circle()
                    .stroke(color, lineWidth: 3)
                    .frame(width: 44, height: 44)
                    .scaleEffect(1.0 + (rippleProgress * 1.6))
                    .opacity(Double(1.0 - rippleProgress))
                    .position(x: localRect.midX, y: localRect.midY)
                    .onAppear {
                        withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) {
                            rippleProgress = 1.0
                        }
                    }

            case .directionalArrow(let direction, let color):
                ArrowShape(direction: direction)
                    .fill(color.opacity(0.95))
                    .frame(width: 40, height: 40)
                    .shadow(color: color.opacity(0.5), radius: 8)
                    .position(x: localRect.midX, y: localRect.midY)

            case .spotlight(let dimOpacity):
                // Dim the entire overlay EXCEPT the highlight rect (even-odd cutout).
                SpotlightMask(holeRect: localRect)
                    .fill(Color.black.opacity(dimOpacity), style: FillStyle(eoFill: true))
            }
        }
        .allowsHitTesting(false)
    }
}

/// A chevron arrow pointing in one of four directions, drawn inside its frame.
struct ArrowShape: Shape {
    let direction: PlatoHighlight.ArrowDirection

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch direction {
        case .down:
            path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        case .up:
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        case .left:
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        case .right:
            path.move(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        }
        path.closeSubpath()
        return path
    }
}

/// Full overlay rect with a rounded-rect hole punched out via the even-odd rule.
struct SpotlightMask: Shape {
    let holeRect: CGRect

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        path.addRoundedRect(in: holeRect, cornerSize: CGSize(width: 8, height: 8))
        return path
    }
}
