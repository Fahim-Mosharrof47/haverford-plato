// MARK: - Plato
//
//  AXElementResolver.swift
//  leanring-buddy
//
//  Resolves the on-screen FRAME of a UI control via the Accessibility API so the
//  overlay can point at / ring the REAL control instead of trusting the model's
//  guessed pixel coordinates. Reads only — no clicking, no actuation: Plato is a
//  teaching companion that points and highlights only. Runs under the Accessibility grant
//  Plato already holds (no new TCC prompt).
//
//  Two strategies:
//   - controlFrame(matchingLabel:) — PRIMARY. Search the FRONTMOST app's AX tree
//     for a control whose title/description matches the model's label ("Print").
//     Robust to a grossly-wrong coordinate guess: finds the control by NAME.
//   - elementFrameAtAppKitPoint(_:) — secondary hit-test under a point.
//
//  COORDINATE FACTS (verified): AX geometry is global TOP-LEFT-origin POINTS
//  anchored to the PRIMARY screen — no backingScaleFactor. AXUIElementCopy-
//  ElementAtPosition takes C Float (must cast). The AX API is NOT thread-safe:
//  every call runs on the main thread (this enum is @MainActor).
//

import AppKit
import ApplicationServices

@MainActor
enum AXElementResolver {

    /// Height of the primary (menu-bar, origin == .zero) screen — the AX flip reference.
    static func primaryScreenHeight() -> CGFloat {
        NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height
            ?? 0
    }

    /// PRIMARY: searches the frontmost app's AX tree for a pointable control whose
    /// title/description/help contains `label` (case-insensitive), returning its
    /// global AppKit frame. nil if not found or the app is AX-blind. Bounded by a
    /// node budget + max depth; a short messaging timeout keeps a slow app from
    /// stalling the main thread.
    static func controlFrame(matchingLabel label: String) -> CGRect? {
        let primaryHeight = primaryScreenHeight()
        guard primaryHeight > 0 else { return nil }
        let normalizedQuery = label.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedQuery.count >= 2 else { return nil }
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }

        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.25)

        let pointableRoles: Set<String> = [
            kAXButtonRole, kAXMenuButtonRole, kAXPopUpButtonRole, kAXMenuItemRole,
            kAXMenuBarItemRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXImageRole
        ]
        let titleAttributes = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute]
        var remainingNodeBudget = 2000

        func search(_ element: AXUIElement, depth: Int) -> CGRect? {
            if remainingNodeBudget <= 0 || depth > 60 { return nil }
            remainingNodeBudget -= 1

            if let role = stringAttribute(element, kAXRoleAttribute), pointableRoles.contains(role) {
                for attribute in titleAttributes {
                    if let text = stringAttribute(element, attribute),
                       text.lowercased().contains(normalizedQuery),
                       let frame = frameOfElement(element, primaryHeight: primaryHeight) {
                        return frame
                    }
                }
            }
            guard let children = childElements(element) else { return nil }
            for child in children {
                if let found = search(child, depth: depth + 1) { return found }
            }
            return nil
        }
        return search(appElement, depth: 0)
    }

    /// SECONDARY: hit-tests the element under a GLOBAL AppKit point and returns its
    /// frame in global AppKit coordinates, or nil if AX exposes nothing there.
    static func elementFrameAtAppKitPoint(_ appKitPoint: CGPoint) -> CGRect? {
        let primaryHeight = primaryScreenHeight()
        guard primaryHeight > 0 else { return nil }

        // AppKit (bottom-left) -> AX/CG (top-left): X identical, flip Y.
        let topLeftX = Float(appKitPoint.x)
        let topLeftY = Float(primaryHeight - appKitPoint.y)

        let systemWide = AXUIElementCreateSystemWide()
        var hitElement: AXUIElement?
        let hitStatus = AXUIElementCopyElementAtPosition(systemWide, topLeftX, topLeftY, &hitElement)
        guard hitStatus == .success, let element = hitElement else { return nil }
        return frameOfElement(element, primaryHeight: primaryHeight)
    }

    // MARK: - AX reading helpers

    /// Reads kAXPosition + kAXSize and converts to a global AppKit rect, or nil.
    private static func frameOfElement(_ element: AXUIElement, primaryHeight: CGFloat) -> CGRect? {
        var positionValue: AnyObject?
        var sizeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionAXValue = positionValue, CFGetTypeID(positionAXValue) == AXValueGetTypeID(),
              let sizeAXValue = sizeValue, CFGetTypeID(sizeAXValue) == AXValueGetTypeID() else {
            return nil
        }
        var axOrigin = CGPoint.zero
        var axSize = CGSize.zero
        guard AXValueGetValue(positionAXValue as! AXValue, .cgPoint, &axOrigin),
              AXValueGetValue(sizeAXValue as! AXValue, .cgSize, &axSize),
              axSize.width > 0, axSize.height > 0 else {
            return nil
        }
        return HighlightGeometry.appKitRectFromAXFrame(
            axOrigin: axOrigin, axSize: axSize, primaryScreenHeight: primaryHeight
        )
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func childElements(_ element: AXUIElement) -> [AXUIElement]? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return nil }
        return value as? [AXUIElement]
    }
}
