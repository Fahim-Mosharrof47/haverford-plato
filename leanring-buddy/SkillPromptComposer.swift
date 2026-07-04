// MARK: - Skilly

import Foundation

/// Holds a previously composed prompt alongside the cache key used to generate it,
/// so repeated calls with the same skill+stage state skip recomposition.
struct PromptCache {
    var cachedPrompt: String?
    var cacheKey: String?
}

/// Namespace for assembling the layered system prompt that Claude receives when a skill is active.
///
/// The composed prompt is built from up to five layers:
///  1. The base system prompt (always first)
///  2. The active skill's teaching instructions
///  3. Curriculum context for the current stage
///  4. Vocabulary entries trimmed to fit the token budget
///  5. A pointing-mode instruction tuned to the skill's configured aggressiveness
enum SkillPromptComposer {

    // MARK: - Public API

    /// Returns a composed prompt, serving from cache when the skill/stage state has not changed.
    ///
    /// The cache key is formed from `skillId + ":" + stageId`. If the stored key matches the
    /// current state, the cached prompt is returned without recomposition. Otherwise the prompt
    /// is recomposed and the cache is updated in-place.
    ///
    /// - Parameters:
    ///   - basePrompt: The static system prompt that always appears at the start.
    ///   - skill: The active `SkillDefinition` providing instructions and curriculum.
    ///   - progress: The user's current `SkillProgress` within the skill.
    ///   - cache: An inout `PromptCache` used to avoid redundant recomposition.
    /// - Returns: The fully assembled system prompt string.
    static func compose(
        basePrompt: String,
        skill: SkillDefinition,
        progress: SkillProgress,
        cache: inout PromptCache
    ) -> String {
        let currentCacheKey = "\(skill.metadata.id):\(progress.currentStageId)"

        // Return the cached prompt when the skill and stage have not changed.
        if cache.cacheKey == currentCacheKey, let existingCachedPrompt = cache.cachedPrompt {
            return existingCachedPrompt
        }

        // Recompose and update the cache.
        let freshlyComposedPrompt = compose(basePrompt: basePrompt, skill: skill, progress: progress)
        cache.cachedPrompt = freshlyComposedPrompt
        cache.cacheKey = currentCacheKey
        return freshlyComposedPrompt
    }

    /// Composes the full layered system prompt without caching.
    ///
    /// Builds all five layers and joins them with double newlines so each layer is visually
    /// separated in the prompt Claude receives.
    ///
    /// - Parameters:
    ///   - basePrompt: The static system prompt that always appears at the start.
    ///   - skill: The active `SkillDefinition` providing instructions and curriculum.
    ///   - progress: The user's current `SkillProgress` within the skill.
    /// - Returns: The fully assembled system prompt string.
    static func compose(
        basePrompt: String,
        skill: SkillDefinition,
        progress: SkillProgress
    ) -> String {
        if let rustComposedPrompt = RustSkillsBridge.shared.composePrompt(
            basePrompt: basePrompt,
            skill: skill,
            progress: progress
        ) {
            return rustComposedPrompt
        }

        return composeWithSwift(
            basePrompt: basePrompt,
            skill: skill,
            progress: progress
        )
    }

    /// Swift fallback prompt composer used when the Rust bridge is unavailable.
    private static func composeWithSwift(
        basePrompt: String,
        skill: SkillDefinition,
        progress: SkillProgress
    ) -> String {
        var sections: [String] = []

        // Layer 1: Base system prompt — always first so it sets the foundational identity.
        sections.append(basePrompt)

        // Layer 2: Active skill header + teaching instructions.
        let escapedSkillName = escapePromptDelimiters(skill.metadata.name)
        let escapedTeachingInstructions = escapePromptDelimiters(skill.teachingInstructions)
        let skillHeader = "--- ACTIVE SKILL: \(escapedSkillName) ---\n\n\(escapedTeachingInstructions)"
        sections.append(skillHeader)

        // Layer 3: Curriculum context showing current stage, completed stages, and what's next.
        let curriculumContext = composeCurriculumContext(skill: skill, progress: progress)
        if !curriculumContext.isEmpty {
            sections.append(curriculumContext)
        }

        // Layer 4: Vocabulary entries trimmed to fit within the vocabulary token budget.
        let vocabularyContext = composeVocabularyContext(skill: skill, progress: progress)
        if !vocabularyContext.isEmpty {
            sections.append(vocabularyContext)
        }

        // Layer 5: Pointing mode instruction tailored to how aggressively Claude should point.
        let pointingInstruction = pointingModeInstruction(
            mode: skill.metadata.pointingMode,
            targetApp: skill.metadata.targetApp
        )
        sections.append(pointingInstruction)

        return sections.joined(separator: "\n\n")
    }

    // MARK: - Private Helpers

    /// Builds the curriculum context block showing the current stage, its goals,
    /// any already-completed stages, and the name of the upcoming stage.
    private static func composeCurriculumContext(skill: SkillDefinition, progress: SkillProgress) -> String {
        // Look up the current stage definition; return empty string if not found.
        guard let currentStage = skill.curriculumStages.first(where: { $0.id == progress.currentStageId }) else {
            return ""
        }

        var lines: [String] = []
        lines.append("--- LEARNING PROGRESS ---")
        lines.append("Current stage: \(escapePromptDelimiters(currentStage.name))")

        // List the goals for the current stage as bullet items.
        lines.append("Goals for this stage:")
        for stageGoal in currentStage.goals {
            lines.append("- \(escapePromptDelimiters(stageGoal))")
        }

        // Show previously completed stages if any exist.
        if !progress.completedStageIds.isEmpty {
            // Map completed stage IDs to their human-readable names where possible.
            let completedStageNames: [String] = progress.completedStageIds.compactMap { completedStageId in
                guard let completedStageName = skill.curriculumStages.first(where: { $0.id == completedStageId })?.name else {
                    return nil
                }
                return escapePromptDelimiters(completedStageName)
            }
            if !completedStageNames.isEmpty {
                lines.append("Completed stages: \(completedStageNames.joined(separator: ", "))")
            }
        }

        // Show the name of the next stage when one exists.
        if let nextStageName = currentStage.nextStageName {
            lines.append("Next up: \(escapePromptDelimiters(nextStageName))")
        }

        return lines.joined(separator: "\n")
    }

    /// Builds the vocabulary reference block from the skill's vocabulary entries,
    /// trimmed to fit within `PromptBudget.vocabularyBudget` estimated tokens.
    private static func composeVocabularyContext(skill: SkillDefinition, progress: SkillProgress) -> String {
        guard !skill.vocabularyEntries.isEmpty else {
            return ""
        }

        // Find the current stage so trimVocabulary can filter by stage relevance.
        guard let currentStage = skill.curriculumStages.first(where: { $0.id == progress.currentStageId }) else {
            // No matching stage; include all entries without trimming.
            let allEntriesFormatted = skill.vocabularyEntries
                .map {
                    "\(escapePromptDelimiters($0.name)): \(escapePromptDelimiters($0.description))"
                }
                .joined(separator: "\n")
            return "--- UI ELEMENT REFERENCE ---\n\(allEntriesFormatted)"
        }

        let trimmedEntries = PromptBudget.trimVocabulary(
            entries: skill.vocabularyEntries,
            currentStage: currentStage,
            budget: PromptBudget.vocabularyBudget
        )

        guard !trimmedEntries.isEmpty else {
            return ""
        }

        let formattedEntries = trimmedEntries
            .map {
                "\(escapePromptDelimiters($0.name)): \(escapePromptDelimiters($0.description))"
            }
            .joined(separator: "\n")

        return "--- UI ELEMENT REFERENCE ---\n\(formattedEntries)"
    }

    /// Returns the pointing-mode instruction sentence appropriate for the given mode and target app.
    private static func pointingModeInstruction(mode: PointingMode, targetApp: String) -> String {
        // MARK: - Plato
        let highlightGuidance = " Show, don't just tell: whenever your spoken answer refers to something the user can see — a control, menu, icon, panel, region, or a specific piece of text — point at it or highlight it in the SAME response so they see exactly what you mean instead of hunting for it. Default to showing; a purely verbal answer about an on-screen thing is a fallback, not the norm. For a control (button, menu, icon) call point_at_element with its exact on-screen NAME as the label — Plato uses that name to find and ring the real control precisely. To emphasize a region of a document or paper, call highlight_region (or, once you know the exact visible text, highlight_text). To draw the eye to a single click target, call ripple_here. When you walk the user through several things in order, show each one as you name it — point at or highlight every step, not only the first. If the thing the user needs is scrolled off-screen, call show_scroll_affordance with the direction and tell them to scroll; highlight it once it becomes visible. Only skip showing when there is genuinely nothing on screen to show, the target is not visible, or you cannot name it — and in that case do NOT point at a guess: say the menu path out loud instead (e.g. File ▸ Print). Every highlight only ever ADDS to your spoken answer — always speak normally too. Highlights are momentary; never rely on them persisting. Never say coordinates, colors-as-data, or tool names aloud."

        switch mode {
        case .always:
            return "When helping with \(targetApp), aggressively point at UI elements using the vocabulary above. The user is learning and needs visual guidance. Err on the side of pointing rather than not pointing." + highlightGuidance
        case .whenRelevant:
            return "When helping with \(targetApp), point at UI elements when it would genuinely help the user find something they're looking for. Don't point at things that are obvious or that the user is already looking at." + highlightGuidance
        case .minimal:
            return "When helping with \(targetApp), only point at UI elements when the user explicitly asks where something is or is clearly lost. Default to verbal descriptions unless pointing adds significant clarity." + highlightGuidance
        }
    }

    // MARK: - Skilly

    private static func escapePromptDelimiters(_ text: String) -> String {
        text.replacingOccurrences(of: "---", with: "—")
    }
}
