// MARK: - Plato
//
//  HighlightGeometry.swift
//  leanring-buddy
//
//  Pure coordinate math for visual highlights. Three coordinate spaces are in
//  play and getting them wrong silently flips/offsets boxes:
//   - Screenshot pixels: TOP-LEFT origin, +Y down (what the model returns).
//   - Vision normalized:  BOTTOM-LEFT origin, 0...1 (what VNRecognizedText gives).
//   - Global AppKit:      BOTTOM-LEFT origin, points (NSEvent.mouseLocation,
//                         NSScreen.frame, displayFrame, the overlay's space).
//  Everything in this file is pure so it can be unit-tested without the app.
//

import CoreGraphics

enum HighlightGeometry {

    /// How far outside the screenshot a coordinate may fall (as a fraction of
    /// the image dimension) before it is treated as hallucinated and declined
    /// instead of clamped. Small overshoot is normal model rounding; a
    /// coordinate way outside the image means the model made the point up, and
    /// clamping it to a screen edge points confidently at nothing.
    static let outOfRangePixelTolerance: CGFloat = 0.02

    /// Screenshot pixel point (top-left origin) -> global AppKit point
    /// (bottom-left origin), or nil when the coordinates fall outside the
    /// screenshot by more than `outOfRangePixelTolerance` (decline > mis-point).
    /// The single source of truth for point mapping — CompanionManager used to
    /// carry a duplicate of this math.
    static func globalPointFromScreenshotPixel(
        x: Int, y: Int,
        screenshotWidthInPixels: Int, screenshotHeightInPixels: Int,
        displayFrame: CGRect
    ) -> CGPoint? {
        let safeWidthInPixels = max(screenshotWidthInPixels, 1)
        let safeHeightInPixels = max(screenshotHeightInPixels, 1)

        let xToleranceInPixels = CGFloat(safeWidthInPixels) * outOfRangePixelTolerance
        let yToleranceInPixels = CGFloat(safeHeightInPixels) * outOfRangePixelTolerance
        guard CGFloat(x) >= -xToleranceInPixels,
              CGFloat(x) <= CGFloat(screenshotWidthInPixels) + xToleranceInPixels,
              CGFloat(y) >= -yToleranceInPixels,
              CGFloat(y) <= CGFloat(screenshotHeightInPixels) + yToleranceInPixels else {
            return nil
        }

        let clampedXInPixels = max(0, min(x, screenshotWidthInPixels))
        let clampedYInPixels = max(0, min(y, screenshotHeightInPixels))

        let normalizedX = CGFloat(clampedXInPixels) / CGFloat(safeWidthInPixels)
        let normalizedY = CGFloat(clampedYInPixels) / CGFloat(safeHeightInPixels)

        let globalX = displayFrame.minX + (displayFrame.width * normalizedX)
        // The screenshot's TOP edge maps to a HIGH AppKit Y (bottom-left origin).
        let globalY = displayFrame.maxY - (displayFrame.height * normalizedY)
        return CGPoint(x: globalX, y: globalY)
    }

    /// Screenshot pixel rect (top-left origin) -> global AppKit rect (bottom-left
    /// origin). Width/height scale by the same normalization factor as x/y
    /// because all four originate in the same screenshot pixel space. The rect
    /// is clamped INSIDE the image (origin and extent), so the resulting global
    /// rect never runs past the display edge.
    static func globalRectFromScreenshotPixelRect(
        x: Int, y: Int, width: Int, height: Int,
        screenshotWidthInPixels: Int, screenshotHeightInPixels: Int,
        displayFrame: CGRect
    ) -> CGRect {
        let safeWidthInPixels = max(screenshotWidthInPixels, 1)
        let safeHeightInPixels = max(screenshotHeightInPixels, 1)

        let clampedX = max(0, min(x, screenshotWidthInPixels))
        let clampedY = max(0, min(y, screenshotHeightInPixels))
        // Clamp the far edge too: x+width beyond the image would otherwise map
        // to a box visually running off the display.
        let clampedWidth = max(0, min(width, screenshotWidthInPixels - clampedX))
        let clampedHeight = max(0, min(height, screenshotHeightInPixels - clampedY))

        let normalizedX = CGFloat(clampedX) / CGFloat(safeWidthInPixels)
        let normalizedY = CGFloat(clampedY) / CGFloat(safeHeightInPixels)
        let normalizedWidth = CGFloat(clampedWidth) / CGFloat(safeWidthInPixels)
        let normalizedHeight = CGFloat(clampedHeight) / CGFloat(safeHeightInPixels)

        let globalX = displayFrame.minX + (displayFrame.width * normalizedX)
        // The screenshot's TOP edge maps to a HIGH AppKit Y (bottom-left origin).
        let globalTopEdgeY = displayFrame.maxY - (displayFrame.height * normalizedY)
        let globalWidth = displayFrame.width * normalizedWidth
        let globalHeight = displayFrame.height * normalizedHeight
        // Subtract the height to get the bottom-left ORIGIN of the rect.
        return CGRect(x: globalX, y: globalTopEdgeY - globalHeight,
                      width: globalWidth, height: globalHeight)
    }

    /// Vision normalized box (0...1, bottom-left origin) -> global AppKit rect.
    /// No Y flip: Vision and AppKit share bottom-left handedness. Normalized
    /// coordinates are dimensionless, so the 1280px capture downscale and the
    /// Retina backing scale are both irrelevant here.
    static func globalRectFromNormalizedVisionBox(_ box: CGRect, displayFrame: CGRect) -> CGRect {
        CGRect(
            x: displayFrame.minX + (box.minX * displayFrame.width),
            y: displayFrame.minY + (box.minY * displayFrame.height),
            width: box.width * displayFrame.width,
            height: box.height * displayFrame.height
        )
    }

    /// Global AppKit rect (bottom-left origin) -> overlay-local SwiftUI rect
    /// (top-left origin) for the overlay window covering `screenFrame`. Mirrors
    /// BlueCursorView.convertScreenPointToSwiftUICoordinates but flips the whole
    /// rect: the rect's TOP edge in SwiftUI = its global TOP edge (origin.y + height).
    static func localRectFromGlobalRect(_ globalFrame: CGRect, screenFrame: CGRect) -> CGRect {
        let localX = globalFrame.origin.x - screenFrame.origin.x
        let localY = (screenFrame.origin.y + screenFrame.height) - (globalFrame.origin.y + globalFrame.height)
        return CGRect(x: localX, y: localY, width: globalFrame.width, height: globalFrame.height)
    }

    /// AX element frame (global TOP-LEFT-origin points, anchored to the primary
    /// screen) -> global AppKit rect (bottom-left origin). X is identical; flip Y
    /// only, against the PRIMARY screen height. No pixel/backingScaleFactor math.
    static func appKitRectFromAXFrame(axOrigin: CGPoint, axSize: CGSize, primaryScreenHeight: CGFloat) -> CGRect {
        let appKitY = primaryScreenHeight - axOrigin.y - axSize.height
        return CGRect(x: axOrigin.x, y: appKitY, width: axSize.width, height: axSize.height)
    }
}
