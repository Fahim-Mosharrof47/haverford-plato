//
//  CompanionScreenCaptureUtility.swift
//  leanring-buddy
//
//  Standalone screenshot capture for the companion voice flow.
//  Decoupled from the legacy ScreenshotManager so the companion mode
//  can capture screenshots independently without session state.
//

import AppKit
import ScreenCaptureKit

struct CompanionScreenCapture {
    let imageData: Data
    let label: String
    let isCursorScreen: Bool
    let displayWidthInPoints: Int
    let displayHeightInPoints: Int
    let displayFrame: CGRect
    let screenshotWidthInPixels: Int
    let screenshotHeightInPixels: Int
}

@MainActor
enum CompanionScreenCaptureUtility {

    /// Captures all connected displays as JPEG data, labeling each with
    /// whether the user's cursor is on that screen. This gives the AI
    /// full context across multiple monitors.
    static func captureAllScreensAsJPEG() async throws -> [CompanionScreenCapture] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard !content.displays.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No display available for capture"])
        }

        let mouseLocation = NSEvent.mouseLocation

        // Exclude all windows belonging to this app so the AI sees
        // only the user's content, not our overlays or panels.
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownAppWindows = content.windows.filter { window in
            window.owningApplication?.bundleIdentifier == ownBundleIdentifier
        }

        // Build a lookup from display ID to NSScreen so we can use AppKit-coordinate
        // frames instead of CG-coordinate frames. NSEvent.mouseLocation and NSScreen.frame
        // both use AppKit coordinates (bottom-left origin), while SCDisplay.frame uses
        // Core Graphics coordinates (top-left origin). On multi-display setups, the Y
        // origins differ for secondary displays, which breaks cursor-contains checks
        // and downstream coordinate conversions.
        var nsScreenByDisplayID: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                nsScreenByDisplayID[screenNumber] = screen
            }
        }

        // Sort displays so the cursor screen is always first
        let sortedDisplays = content.displays.sorted { displayA, displayB in
            let frameA = nsScreenByDisplayID[displayA.displayID]?.frame ?? displayA.frame
            let frameB = nsScreenByDisplayID[displayB.displayID]?.frame ?? displayB.frame
            let aContainsCursor = frameA.contains(mouseLocation)
            let bContainsCursor = frameB.contains(mouseLocation)
            if aContainsCursor != bContainsCursor { return aContainsCursor }
            return false
        }

        var capturedScreens: [CompanionScreenCapture] = []

        for (displayIndex, display) in sortedDisplays.enumerated() {
            // Use NSScreen.frame (AppKit coordinates, bottom-left origin) so
            // displayFrame is in the same coordinate system as NSEvent.mouseLocation
            // and the overlay window's screenFrame in BlueCursorView.
            let displayFrame = nsScreenByDisplayID[display.displayID]?.frame
                ?? CGRect(x: display.frame.origin.x, y: display.frame.origin.y,
                          width: CGFloat(display.width), height: CGFloat(display.height))
            let isCursorScreen = displayFrame.contains(mouseLocation)

            let filter = SCContentFilter(display: display, excludingWindows: ownAppWindows)

            let configuration = SCStreamConfiguration()
            // MARK: - Plato — 1600px cap (was 1280). At 1280 a 3024px-wide Retina
            // display is downscaled 2.4×, turning small toolbar icons into ~12px
            // smudges the model cannot see — it then guesses coordinates from
            // prior knowledge of the app's layout (root-cause C1; DaVinci "FX"
            // icon repro landed half a screen off). 1600 trades ~1.5-2× vision
            // tokens for legible icons.
            let maxDimension = 1600
            let aspectRatio = CGFloat(display.width) / CGFloat(display.height)
            if display.width >= display.height {
                configuration.width = maxDimension
                configuration.height = Int(CGFloat(maxDimension) / aspectRatio)
            } else {
                configuration.height = maxDimension
                configuration.width = Int(CGFloat(maxDimension) * aspectRatio)
            }

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )

            guard let jpegData = NSBitmapImageRep(cgImage: cgImage)
                    .representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
                continue
            }

            let screenLabel: String
            if sortedDisplays.count == 1 {
                screenLabel = "user's screen (cursor is here)"
            } else if isCursorScreen {
                screenLabel = "screen \(displayIndex + 1) of \(sortedDisplays.count) — cursor is on this screen (primary focus)"
            } else {
                screenLabel = "screen \(displayIndex + 1) of \(sortedDisplays.count) — secondary screen"
            }

            capturedScreens.append(CompanionScreenCapture(
                imageData: jpegData,
                label: screenLabel,
                isCursorScreen: isCursorScreen,
                displayWidthInPoints: Int(displayFrame.width),
                displayHeightInPoints: Int(displayFrame.height),
                displayFrame: displayFrame,
                // MARK: - Plato — declared px MUST equal actual px. These values
                // are what the model is told to answer in AND what the mapping
                // divides by; ScreenCaptureKit may round the requested size, and
                // any requested-vs-actual mismatch becomes a systematic offset.
                screenshotWidthInPixels: cgImage.width,
                screenshotHeightInPixels: cgImage.height
            ))
        }

        guard !capturedScreens.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to capture any screen"])
        }

        return capturedScreens
    }

    // MARK: - Plato — Fresh native-resolution capture for OCR only
    /// Captures ONE display (identified by its AppKit frame) at native Retina
    /// resolution, at the moment of the call. Used exclusively by highlight_text:
    /// the per-turn 1280px JPEG is both seconds stale (the user may have
    /// scrolled) and too small for Vision to read paper body text reliably.
    /// This image is never sent to the model, so resolution costs no tokens.
    static func captureDisplayImageForOCR(displayFrame: CGRect) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        var nsScreenByDisplayID: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                nsScreenByDisplayID[screenNumber] = screen
            }
        }

        guard let display = content.displays.first(where: {
            nsScreenByDisplayID[$0.displayID]?.frame == displayFrame
        }) else {
            throw NSError(domain: "CompanionScreenCapture", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "No display matches the requested frame"])
        }

        // Exclude our own overlay/panel windows so a highlight already on screen
        // never feeds back into the OCR image.
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownAppWindows = content.windows.filter { window in
            window.owningApplication?.bundleIdentifier == ownBundleIdentifier
        }
        let filter = SCContentFilter(display: display, excludingWindows: ownAppWindows)

        let configuration = SCStreamConfiguration()
        // MARK: - Plato — never assume a 2.0 (Retina) scale. The display was
        // matched via its NSScreen frame above, so the NSScreen is present in
        // practice; if it is somehow absent, capture at the logical size (scale 1)
        // rather than a guessed 2.0, which would allocate a wrong-size buffer on a
        // 1x or 3x display. OCR uses NORMALIZED boxes, so a lower-res fallback
        // image never affects pointing accuracy.
        let backingScaleFactor = nsScreenByDisplayID[display.displayID]?.backingScaleFactor ?? 1.0
        configuration.width = Int(CGFloat(display.width) * backingScaleFactor)
        configuration.height = Int(CGFloat(display.height) * backingScaleFactor)

        return try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
    }

    // MARK: - Plato — native-resolution crop for point re-localization (step 3c)

    /// A native-resolution close-up of one region of a display, plus the exact
    /// global AppKit rect it covers — so a pixel the model picks INSIDE the crop
    /// maps back to a precise global point.
    struct CompanionCropCapture {
        let imageData: Data
        /// Global AppKit rect (bottom-left origin) the crop image covers.
        let cropGlobalRect: CGRect
        let cropPixelWidth: Int
        let cropPixelHeight: Int
    }

    /// Captures a square region (side `cropSideInPoints`, clamped to the display)
    /// centered on `globalPoint`, at native Retina resolution. Icons that are
    /// ~12px smudges in the per-turn screenshot are full-size here, so the model
    /// can re-localize what it could not see the first time.
    static func captureNativeResolutionCrop(
        aroundGlobalPoint globalPoint: CGPoint,
        displayFrame: CGRect,
        cropSideInPoints: CGFloat
    ) async throws -> CompanionCropCapture {
        let displayImage = try await captureDisplayImageForOCR(displayFrame: displayFrame)

        // Points → image pixels. The capture spans exactly displayFrame, so the
        // scale is actual-image-width / display-width (never assume 2.0 Retina).
        let pixelsPerPoint = CGFloat(displayImage.width) / max(displayFrame.width, 1)
        let cropSideInPixels = cropSideInPoints * pixelsPerPoint

        // Desired crop center in the image's TOP-LEFT-origin pixel space.
        let centerXInPixels = (globalPoint.x - displayFrame.minX) * pixelsPerPoint
        let centerYInPixels = (displayFrame.maxY - globalPoint.y) * pixelsPerPoint

        // Clamp the crop rect inside the image (shifting it rather than
        // shrinking it near edges, so the target stays comfortably inside).
        let maxOriginX = max(0, CGFloat(displayImage.width) - cropSideInPixels)
        let maxOriginY = max(0, CGFloat(displayImage.height) - cropSideInPixels)
        let cropPixelRect = CGRect(
            x: min(max(0, centerXInPixels - cropSideInPixels / 2), maxOriginX),
            y: min(max(0, centerYInPixels - cropSideInPixels / 2), maxOriginY),
            width: min(cropSideInPixels, CGFloat(displayImage.width)),
            height: min(cropSideInPixels, CGFloat(displayImage.height))
        ).integral

        guard let croppedImage = displayImage.cropping(to: cropPixelRect),
              let jpegData = NSBitmapImageRep(cgImage: croppedImage)
                .representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else {
            throw NSError(domain: "CompanionScreenCapture", code: -4,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to crop display image"])
        }

        // Back-map the ACTUAL cropped pixel rect (post-clamp, post-integral,
        // post-cropping) to the global AppKit rect it covers. Use the cropped
        // image's real dimensions so declared px == actual px.
        let cropGlobalRect = CGRect(
            x: displayFrame.minX + cropPixelRect.minX / pixelsPerPoint,
            y: displayFrame.maxY - (cropPixelRect.minY + cropPixelRect.height) / pixelsPerPoint,
            width: CGFloat(croppedImage.width) / pixelsPerPoint,
            height: CGFloat(croppedImage.height) / pixelsPerPoint
        )

        return CompanionCropCapture(
            imageData: jpegData,
            cropGlobalRect: cropGlobalRect,
            cropPixelWidth: croppedImage.width,
            cropPixelHeight: croppedImage.height
        )
    }
}
