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
//   - controlFrame(matchingLabel:near:) — PRIMARY. Search the FRONTMOST app's AX
//     tree for controls whose title/description matches the model's label
//     ("Print"), then rank the candidates (exact > prefix > substring, on-screen
//     only, nearest to the model's approximate point) via AXCandidateScoring.
//     Declines on a genuine tie — wrong-target pointing is worse than none.
//   - elementFrameAtAppKitPoint(_:) — secondary hit-test under a point.
//
//  COORDINATE FACTS (verified): AX geometry is global TOP-LEFT-origin POINTS
//  anchored to the PRIMARY screen — no backingScaleFactor. AXUIElementCopy-
//  ElementAtPosition takes C Float (must cast). The AX API is NOT thread-safe:
//  every call runs on the main thread (this enum is @MainActor).
//
//  BUDGETS: the tree walk is bounded three ways — a node budget (2000), a max
//  depth (60), and a WALL-CLOCK deadline (0.2s). The messaging timeout is set on
//  the system-wide element, which per the AX contract applies it to every
//  AXUIElementRef this process creates (setting it only on the app root would
//  leave child refs on the ~6s global default — a slow Electron app could then
//  stall the main thread for seconds per call).
//

import AppKit
import ApplicationServices

@MainActor
enum AXElementResolver {

    /// Max wall-clock time the label search may spend walking the AX tree.
    private static let treeWalkDeadlineSeconds: TimeInterval = 0.2

    /// Per-message AX IPC timeout, applied process-wide via the system-wide element.
    private static let messagingTimeoutSeconds: Float = 0.25

    /// A prefix/substring name match farther than this fraction of the hosting
    /// display's larger edge from the model's hinted point is declined. Generous
    /// enough to absorb the model's coordinate imprecision, tight enough to reject
    /// a same-word control across the screen. Fraction (not a fixed pixel count)
    /// so it behaves identically on a 13" laptop and a 32" 6K display.
    private static let inexactMatchProximityFraction: CGFloat = 0.33

    /// Height of the primary (menu-bar, origin == .zero) screen — the AX flip reference.
    static func primaryScreenHeight() -> CGFloat {
        NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height
            ?? 0
    }

    /// Applies the short messaging timeout to EVERY AXUIElementRef this process
    /// creates (system-wide element semantics), so no single hung element can
    /// block the main thread for the ~6s global default.
    private static func applyProcessWideMessagingTimeout() {
        let systemWideElement = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWideElement, messagingTimeoutSeconds)
    }

    /// PRIMARY: searches the frontmost app's AX tree for pointable controls whose
    /// title/description/help contains `label` (case-insensitive), then returns
    /// the best-ranked candidate's global AppKit frame (see AXCandidateScoring).
    /// nil when nothing matches, the app is AX-blind, or the best two candidates
    /// are too close to call. `approximatePoint` is the model's guessed location
    /// (global AppKit), used only to rank same-quality name matches.
    static func controlFrame(matchingLabel label: String, near approximatePoint: CGPoint?) -> CGRect? {
        let primaryHeight = primaryScreenHeight()
        guard primaryHeight > 0 else { return nil }
        let normalizedQuery = label.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedQuery.count >= 2 else { return nil }
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }

        applyProcessWideMessagingTimeout()
        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, messagingTimeoutSeconds)

        // kAXMenuItemRole is deliberately absent: a CLOSED menu's items still
        // report plausible frames, so a name match there rings a control that
        // isn't visible. The prompt tells the model to speak menu paths instead.
        let pointableRoles: Set<String> = [
            kAXButtonRole, kAXMenuButtonRole, kAXPopUpButtonRole,
            kAXMenuBarItemRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXImageRole
        ]
        let titleAttributes = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute]
        var remainingNodeBudget = 2000
        let walkDeadline = Date().addingTimeInterval(treeWalkDeadlineSeconds)
        var matchingCandidates: [AXControlCandidate] = []

        func search(_ element: AXUIElement, depth: Int) {
            if remainingNodeBudget <= 0 || depth > 60 || Date() >= walkDeadline { return }
            remainingNodeBudget -= 1

            if let role = stringAttribute(element, kAXRoleAttribute), pointableRoles.contains(role) {
                for attribute in titleAttributes {
                    if let text = stringAttribute(element, attribute),
                       text.lowercased().contains(normalizedQuery),
                       let frame = frameOfElement(element, primaryHeight: primaryHeight) {
                        matchingCandidates.append(AXControlCandidate(matchedText: text, globalFrame: frame))
                        break
                    }
                }
            }
            guard let children = childElements(element) else { return }
            for child in children {
                if remainingNodeBudget <= 0 || Date() >= walkDeadline { return }
                search(child, depth: depth + 1)
            }
        }
        search(appElement, depth: 0)

        // MARK: - Plato — derive the proximity gate from the actual display the
        // hint falls on (never a hardcoded pixel budget).
        let proximityGate: CGFloat? = approximatePoint.flatMap { hintPoint in
            let hostFrame = (NSScreen.screens.first(where: { $0.frame.contains(hintPoint) })
                             ?? NSScreen.main)?.frame
            guard let hostFrame else { return nil }
            return max(hostFrame.width, hostFrame.height) * inexactMatchProximityFraction
        }
        return AXCandidateScoring.bestCandidate(
            among: matchingCandidates,
            normalizedQuery: normalizedQuery,
            approximatePoint: approximatePoint,
            visibleScreenFrames: NSScreen.screens.map { $0.frame },
            maxDistanceForInexactMatch: proximityGate
        )?.globalFrame
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
        AXUIElementSetMessagingTimeout(systemWide, messagingTimeoutSeconds)
        var hitElement: AXUIElement?
        let hitStatus = AXUIElementCopyElementAtPosition(systemWide, topLeftX, topLeftY, &hitElement)
        guard hitStatus == .success, let element = hitElement,
              let hitFrame = frameOfElement(element, primaryHeight: primaryHeight) else { return nil }

        // MARK: - Plato — reject giant frames. An imprecise guessed point often
        // hit-tests a big container; ringing it lands nowhere near the intended
        // control. Cap is a fraction of the display the point is on (any size).
        let hostFrame = (NSScreen.screens.first(where: { $0.frame.contains(appKitPoint) })
                         ?? NSScreen.main)?.frame ?? .zero
        guard AXCandidateScoring.isPlausibleControlFrame(hitFrame, displayArea: hostFrame.width * hostFrame.height) else {
            return nil
        }
        return hitFrame
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
