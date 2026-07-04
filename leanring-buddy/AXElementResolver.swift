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
//   - elementFrameAtAppKitPoint(_:matchingLabel:) — secondary hit-test under a
//     point that verifies the hit element's identity (name-matched pointable
//     leaf, or a bounded descendant search) before returning a frame.
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

    // MARK: - Plato — Chromium/Electron on-demand accessibility opt-in.
    // Chromium-family apps (Helium, Chrome, Edge, Brave, Arc, CEF) and Electron
    // apps (e.g. Obsidian) expose NO web/renderer AX subtree until an assistive
    // client asks for it via this attribute. Without it the PDF toolbar's Download
    // button simply is not in the tree we walk. Setting it is a no-op error on
    // native apps (attribute unsupported) — safe to set unconditionally, and
    // side-effect-free (unlike AXEnhancedUserInterface, which we deliberately do
    // NOT set: it can make some apps reposition/resize their windows).
    private static let manualAccessibilityAttribute = "AXManualAccessibility"

    /// Best-effort, NON-BLOCKING: tell `processIdentifier`'s app to build its
    /// on-demand accessibility tree. One cheap AX IPC bounded by the process-wide
    /// messaging timeout; no read-back, no wait. Call from PTT press (settle time)
    /// and again just before a walk (catch a frontmost change). Idempotent.
    static func enableOnDemandAccessibility(forProcessIdentifier processIdentifier: pid_t) {
        applyProcessWideMessagingTimeout()
        let appElement = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, messagingTimeoutSeconds)
        // Ignore the status: success on Chromium/Electron, harmless error elsewhere.
        AXUIElementSetAttributeValue(appElement, manualAccessibilityAttribute as CFString, kCFBooleanTrue)
    }

    /// Convenience: arm the current frontmost app (the one the user is looking at
    /// when they press push-to-talk, and the one a tool-call point will target).
    static func enableOnDemandAccessibilityForFrontmostApp() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        enableOnDemandAccessibility(forProcessIdentifier: frontApp.processIdentifier)
    }

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

    // MARK: - Plato — shared across the label walk and the hit-test descent.
    // kAXMenuItemRole deliberately absent: a CLOSED menu's items still report
    // plausible frames, so a name match there rings an invisible control.
    private static let pointableRoles: Set<String> = [
        kAXButtonRole, kAXMenuButtonRole, kAXPopUpButtonRole,
        kAXMenuBarItemRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXImageRole
    ]
    private static let titleAttributes = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute]

    /// True when a pointable element's title/description/help contains the
    /// (already role-stripped) query. Mirrors the label-walk match test so the
    /// hit-test path and the name-search path agree on "matches".
    private static func pointableElementMatches(_ element: AXUIElement, normalizedQuery: String) -> Bool {
        guard let role = stringAttribute(element, kAXRoleAttribute), pointableRoles.contains(role) else {
            return false
        }
        for attribute in titleAttributes {
            if let text = stringAttribute(element, attribute),
               text.lowercased().contains(normalizedQuery) {
                return true
            }
        }
        return false
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
        // MARK: - Plato — strip trailing role words so "download button" matches
        // the accessible name "Download" (exact tier), not never.
        let normalizedQuery = AXCandidateScoring.normalizedControlQuery(from: label)
        guard normalizedQuery.count >= 2 else { return nil }
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }

        // MARK: - Plato — best-effort re-arm (no wait) in case the frontmost app
        // changed since PTT press; the tree from PTT-press arming is what we walk.
        enableOnDemandAccessibility(forProcessIdentifier: frontApp.processIdentifier)
        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, messagingTimeoutSeconds)

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

    /// SECONDARY: hit-tests the element under a GLOBAL AppKit point, then verifies
    /// its IDENTITY before returning a frame. Returns the frame of a pointable leaf
    /// whose name token-matches `label` — either the hit element itself, or, if the
    /// hit is a container (toolbar/group/web area), a bounded descendant search for
    /// such a leaf. nil when nothing under the point matches the requested control
    /// (→ caller falls back to OCR / honest hedge). Never returns a bare container.
    static func elementFrameAtAppKitPoint(_ appKitPoint: CGPoint, matchingLabel label: String) -> CGRect? {
        let primaryHeight = primaryScreenHeight()
        guard primaryHeight > 0 else { return nil }
        let normalizedQuery = AXCandidateScoring.normalizedControlQuery(from: label)
        guard normalizedQuery.count >= 2 else { return nil }

        // AppKit (bottom-left) -> AX/CG (top-left): X identical, flip Y.
        let topLeftX = Float(appKitPoint.x)
        let topLeftY = Float(primaryHeight - appKitPoint.y)

        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, messagingTimeoutSeconds)
        var hitElement: AXUIElement?
        let hitStatus = AXUIElementCopyElementAtPosition(systemWide, topLeftX, topLeftY, &hitElement)
        guard hitStatus == .success, let element = hitElement else { return nil }

        let hostFrame = (NSScreen.screens.first(where: { $0.frame.contains(appKitPoint) })
                         ?? NSScreen.main)?.frame ?? .zero

        // MARK: - Plato — identity check. The hit element must itself be a
        // name-matched pointable leaf, else we descend for one. A bare container
        // (the observed full-width toolbar) is NEVER returned.
        if pointableElementMatches(element, normalizedQuery: normalizedQuery),
           let hitFrame = frameOfElement(element, primaryHeight: primaryHeight),
           AXCandidateScoring.isPlausibleControlFrame(hitFrame, displaySize: hostFrame.size) {
            return hitFrame
        }

        // Container hit: bounded descent for a name-matched pointable leaf. Budgets
        // are small — the hit node is local and shallow (a toolbar has few
        // descendants); this must not stall the turn. 400 nodes / depth 12 / 0.1s.
        var remainingNodeBudget = 400
        let descentDeadline = Date().addingTimeInterval(0.1)

        func firstMatchingDescendant(_ node: AXUIElement, depth: Int) -> CGRect? {
            if remainingNodeBudget <= 0 || depth > 12 || Date() >= descentDeadline { return nil }
            remainingNodeBudget -= 1
            if pointableElementMatches(node, normalizedQuery: normalizedQuery),
               let frame = frameOfElement(node, primaryHeight: primaryHeight),
               AXCandidateScoring.isPlausibleControlFrame(frame, displaySize: hostFrame.size) {
                return frame
            }
            guard let children = childElements(node) else { return nil }
            for child in children {
                if remainingNodeBudget <= 0 || Date() >= descentDeadline { return nil }
                if let found = firstMatchingDescendant(child, depth: depth + 1) { return found }
            }
            return nil
        }
        return firstMatchingDescendant(element, depth: 0)
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
