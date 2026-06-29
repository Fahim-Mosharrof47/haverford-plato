// MARK: - Plato
//
//  OnboardingTargetFrameReporter.swift
//  leanring-buddy
//
//  Reports the live on-screen (AppKit, bottom-left origin) frame of the SwiftUI
//  view it backs, so the guided onboarding tour can fly the blue cursor to a
//  real panel control. It uses NSWindow.convertToScreen, which gives screen
//  coordinates directly — no fragile cross-window coordinate math, and it stays
//  correct if the panel moves or the layout changes.
//

import AppKit
import SwiftUI

/// Drop this into a control's `.background(...)`; it calls back with that
/// control's frame in AppKit screen coordinates whenever it lays out or moves
/// windows. The frame matches `NSEvent.mouseLocation` space, which is exactly
/// what `CompanionManager.detectedElementScreenLocation` expects.
struct OnboardingTargetFrameReporter: NSViewRepresentable {
    let onScreenFrameChange: (CGRect) -> Void

    func makeNSView(context: Context) -> NSView {
        let reportingView = FrameReportingNSView()
        reportingView.onScreenFrameChange = onScreenFrameChange
        return reportingView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let reportingView = nsView as? FrameReportingNSView else { return }
        reportingView.onScreenFrameChange = onScreenFrameChange
        reportingView.reportScreenFrame()
    }
}

private final class FrameReportingNSView: NSView {
    var onScreenFrameChange: ((CGRect) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportScreenFrame()
    }

    override func layout() {
        super.layout()
        reportScreenFrame()
    }

    func reportScreenFrame() {
        // No window means the control isn't on screen (e.g. panel closed); skip
        // so we never report a stale or zero frame.
        guard let hostWindow = window else { return }
        let frameInWindow = convert(bounds, to: nil)
        let frameOnScreen = hostWindow.convertToScreen(frameInWindow)
        onScreenFrameChange?(frameOnScreen)
    }
}
