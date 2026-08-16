//
//  AskKinetic.swift
//  Kinetic Studio
//
//  Type what you want, see exactly what will happen, then decide. The preview is
//  the whole design: a scene command that fires straight off a keystroke is a
//  command you cannot trust, because you never learn what it understood. Nothing
//  here touches the world until Apply.
//
//  The same view serves the command palette and a standalone panel — the only
//  differences are chrome and width, so there is one behaviour to reason about.
//
//  Integration note — why the protocols below exist:
//  `IntentParser` lives in the KineticML target, which is being written in
//  parallel with this file. The view depends on the local protocol below instead,
//  and a built-in phrase matcher satisfies it today. When KineticML lands:
//
//      struct KineticMLInterpreter: SceneIntentInterpreting {
//          func parse(_ text: String, context: IntentContext) -> IntentPreview? {
//              guard let intent = IntentParser.parse(text) else { return nil }
//              return IntentPreview(command: text,
//                                   summary: intent.plan.summary,
//                                   operations: intent.plan.operations.map { ... },
//                                   confidence: intent.confidence,
//                                   unmatched: intent.unmatched,
//                                   notes: IntentParser.explain(intent),
//                                   ...,
//                                   perform: { model in ...apply the ScenePlan... })
//          }
//          func suggestions(for text: String, context: IntentContext) -> [String] {
//              IntentParser.suggestions(for: text)
//          }
//      }
//
//  then `AskKinetic(model: model, interpreter: KineticMLInterpreter())`.
//

import Kinetic
import KineticRender
import SwiftUI

// MARK: - Integration seam

struct SceneOption: Identifiable, Hashable {
    var id: String
    var title: String
}

/// What the interpreter is allowed to know about the running app. Passing this in
/// rather than the model keeps parsing pure and testable.
struct IntentContext {
    var scenes: [SceneOption]
    var channels: [String]
    var isPlaying: Bool
    var isDark: Bool
}

/// One line in the preview list.
struct PlannedOperation: Identifiable {
    let id = UUID()
    var label: String
    var detail: String?
}

/// What applying produced, and how to take it back.
/// Same reasoning as `IntentPreview.Perform`: a name so the attribute lands on
/// the type rather than the declaration.
typealias IntentUndo = @MainActor () -> Void

struct IntentOutcome {
    var message: String
    /// Undoes everything that is not simulation state; the panel restores state
    /// separately from its own snapshot.
    var undo: IntentUndo?
}

/// A parsed command, fully described before anything happens.
///
/// `perform` is a sealed action rather than a list of opcodes so that an
/// interpreter can carry whatever internal plan it likes — the view only ever
/// renders the description and calls this once, from Apply.
struct IntentPreview: Identifiable {
    let id = UUID()
    var command: String
    var summary: String
    var operations: [PlannedOperation]
    /// 0...1. Deliberately never 1: a matcher that claims certainty is lying.
    var confidence: Double
    var unmatched: [String]
    var notes: String
    /// Whether the panel should snapshot simulation state before applying.
    var touchesWorldState: Bool
    var isReversible: Bool
    var perform: Perform

    /// Named so call sites can annotate a closure literal. Writing the attributed
    /// function type inline in a `let` annotation makes the compiler read
    /// `@MainActor` as applying to the declaration, not to the type.
    typealias Perform = @MainActor (StudioModel) -> IntentOutcome
}

protocol SceneIntentInterpreting {
    var engineName: String { get }
    /// One sentence, shown under the preview, describing what this parser is not.
    var disclaimer: String { get }

    func suggestions(for text: String, context: IntentContext) -> [String]
    /// Pure. Returns nil when nothing matched.
    func parse(_ text: String, context: IntentContext) -> IntentPreview?
}

// MARK: - Built-in interpreter

/// Phrase and number matching over a fixed vocabulary. It is not a language
/// model and the UI says so: it looks for known words, reads the first number it
/// finds, and ignores everything else — which is exactly why the unmatched list
/// is shown rather than swallowed.
struct PhraseIntentInterpreter: SceneIntentInterpreting {
    var engineName: String { "Phrase matcher" }
    var disclaimer: String {
        "This matches known phrases and numbers. It does not understand the sentence, "
            + "so read the operations before applying."
    }

    /// One unit of work plus the undo it hands back once it has run.
    private struct Step {
        var operation: PlannedOperation
        var touchesWorldState: Bool
        var isReversible: Bool
        var apply: @MainActor (StudioModel) -> (@MainActor () -> Void)?
    }

    private let stopWords: Set<String> = [
        "the", "a", "an", "to", "please", "make", "set", "and", "it", "that", "this",
        "of", "for", "at", "in", "is", "be", "me", "my", "let", "just", "can", "you",
        "with", "all", "up", "down", "now", "then", "scene", "sim", "simulation",
    ]

    // MARK: Suggestions

    func suggestions(for text: String, context: IntentContext) -> [String] {
        let query = text.lowercased().trimmingCharacters(in: .whitespaces)
        var pool: [String] = [
            "turn off gravity",
            "set gravity to 1.62",
            "restore earth gravity",
            "pause the simulation",
            "run the simulation",
            "reset the scene",
            "step one frame",
            "run at half speed",
            "run at 2x speed",
            "hide the grid",
            "show contacts",
            "show collision shapes",
            "draw wireframe",
            "show trails",
            "switch to the light theme",
            "set timestep to 0.002",
            "use 60 solver iterations",
        ]
        pool.append(contentsOf: context.scenes.prefix(6).map { "load \($0.title)" })
        pool.append(contentsOf: context.channels.prefix(6).map { "plot \($0)" })

        guard !query.isEmpty else { return Array(pool.prefix(6)) }
        // Rank whole-phrase hits above word hits so "grav" does not surface
        // "restore earth gravity" above "turn off gravity".
        let queryWords = query.split(separator: " ").map(String.init)
        let scored = pool.map { candidate -> (String, Int) in
            let lower = candidate.lowercased()
            var score = 0
            if lower.hasPrefix(query) { score += 10 }
            if lower.contains(query) { score += 6 }
            for word in queryWords where word.count > 1 && lower.contains(word) { score += 2 }
            return (candidate, score)
        }
        return scored.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.prefix(6).map { $0.0 }
    }

    // MARK: Parsing

    func parse(_ text: String, context: IntentContext) -> IntentPreview? {
        let lower = text.lowercased()
        let words = tokenise(lower)
        guard !words.isEmpty else { return nil }

        var used = Set<String>()
        var steps: [Step] = []

        appendGravity(lower, words, &used, &steps)
        appendTimestep(lower, words, &used, &steps)
        appendSolver(lower, words, &used, &steps)
        appendTransport(lower, &used, &steps, context: context)
        appendSpeed(lower, words, &used, &steps)
        appendDisplay(lower, &used, &steps)
        appendTheme(lower, &used, &steps, context: context)
        appendScene(lower, &used, &steps, context: context)
        appendPlot(lower, &used, &steps, context: context)

        guard !steps.isEmpty else { return nil }

        let significant = words.filter { !stopWords.contains($0) }
        let unmatched = significant.filter { word in
            !used.contains(word) && Double(word) == nil
        }
        let matchedShare = significant.isEmpty
            ? 0.0
            : Double(significant.count - unmatched.count) / Double(significant.count)
        // Capped below 1 on purpose. Matching every word is not understanding.
        let confidence = min(0.45 + 0.5 * matchedShare, 0.95)

        let summary: String
        if steps.count == 1 {
            let label = steps[0].operation.label
            summary = label.prefix(1).uppercased() + label.dropFirst()
        } else {
            summary = "Apply \(steps.count) changes to the scene."
        }

        // Every sub-expression below is bound to an annotated local first. The
        // initialiser takes two closures and four derived collections, and
        // inlining them all defeats the type checker outright rather than merely
        // slowing it down.
        let sealed: [Step] = steps
        let operations: [PlannedOperation] = sealed.map { $0.operation }
        let noteText: String = notes(matched: sealed.count, unmatched: unmatched)
        let touchesState: Bool = sealed.contains { $0.touchesWorldState }
        let reversible: Bool = sealed.allSatisfy { $0.isReversible }

        let perform: IntentPreview.Perform = { (model: StudioModel) -> IntentOutcome in
            var undos: [IntentUndo] = []
            for step in sealed {
                if let undo = step.apply(model) { undos.append(undo) }
            }
            let message: String = sealed.map { $0.operation.label }.joined(separator: "; ")
            if undos.isEmpty { return IntentOutcome(message: message, undo: nil) }
            // Reverse order: later steps may depend on earlier ones.
            let reverse: IntentUndo = {
                for undo in undos.reversed() { undo() }
            }
            return IntentOutcome(message: message, undo: reverse)
        }

        return IntentPreview(
            command: text,
            summary: summary,
            operations: operations,
            confidence: confidence,
            unmatched: unmatched,
            notes: noteText,
            touchesWorldState: touchesState,
            isReversible: reversible,
            perform: perform)
    }

    private func notes(matched: Int, unmatched: [String]) -> String {
        var note = "Matched \(matched) operation\(matched == 1 ? "" : "s") by phrase."
        if !unmatched.isEmpty {
            note += " \(unmatched.count) word\(unmatched.count == 1 ? "" : "s") "
                + "meant nothing to the matcher and were ignored."
        }
        return note
    }

    // MARK: Rules

    private func appendGravity(_ lower: String, _ words: [String], _ used: inout Set<String>,
                               _ steps: inout [Step]) {
        guard lower.contains("gravity") || lower.contains("weightless") else { return }
        used.formUnion(["gravity", "weightless", "off", "zero", "moon", "mars", "earth",
                        "normal", "restore"])

        let magnitude: Double
        let name: String
        if lower.contains("off") || lower.contains("zero") || lower.contains("weightless")
            || lower.contains("no gravity") {
            magnitude = 0
            name = "zero"
        } else if lower.contains("moon") {
            magnitude = 1.62
            name = "lunar"
        } else if lower.contains("mars") {
            magnitude = 3.72
            name = "martian"
        } else if lower.contains("earth") || lower.contains("normal") {
            magnitude = 9.81
            name = "earth"
        } else if let value = firstNumber(words) {
            magnitude = abs(value)
            name = "custom"
        } else {
            magnitude = 9.81
            name = "earth"
        }

        let target = Vec3(0, 0, -magnitude)
        steps.append(Step(
            operation: PlannedOperation(
                label: String(format: "set gravity to %.2f m/s^2 downward", magnitude),
                detail: "\(name) · applies immediately, does not disturb the current state"),
            touchesWorldState: false, isReversible: true,
            apply: { model in
                let previous = model.world.options.gravity
                model.world.options.gravity = target
                return { model.world.options.gravity = previous }
            }))
    }

    private func appendTimestep(_ lower: String, _ words: [String], _ used: inout Set<String>,
                                _ steps: inout [Step]) {
        guard lower.contains("timestep") || lower.contains("time step") || lower.contains("dt")
        else { return }
        used.formUnion(["timestep", "time", "step", "dt", "ms"])
        guard var value = firstNumber(words) else { return }
        // "2 ms" and "0.002" mean the same thing; anything above 0.1 was surely
        // milliseconds, because a 0.2 s timestep is not a simulation.
        if lower.contains("ms") || value > 0.1 { value /= 1000 }
        let clamped = min(max(value, 1e-5), 0.05)
        steps.append(Step(
            operation: PlannedOperation(
                label: String(format: "set the timestep to %.5f s", clamped),
                detail: "larger steps are faster and less stable"),
            touchesWorldState: false, isReversible: true,
            apply: { model in
                let previous = model.world.options.timestep
                model.world.options.timestep = clamped
                return { model.world.options.timestep = previous }
            }))
    }

    private func appendSolver(_ lower: String, _ words: [String], _ used: inout Set<String>,
                              _ steps: inout [Step]) {
        guard lower.contains("solver") || lower.contains("iteration") else { return }
        used.formUnion(["solver", "iteration", "iterations", "use"])
        guard let value = firstNumber(words) else { return }
        let count = min(max(Int(value), 1), 500)
        steps.append(Step(
            operation: PlannedOperation(label: "use \(count) solver iterations",
                                        detail: "more iterations, tighter constraints, slower steps"),
            touchesWorldState: false, isReversible: true,
            apply: { model in
                let previous = model.world.options.solverIterations
                model.world.options.solverIterations = count
                return { model.world.options.solverIterations = previous }
            }))
    }

    private func appendTransport(_ lower: String, _ used: inout Set<String>,
                                 _ steps: inout [Step], context: IntentContext) {
        if lower.contains("reset") {
            used.formUnion(["reset"])
            steps.append(Step(
                operation: PlannedOperation(label: "reset the scene to its default pose",
                                            detail: "clears plots and the recorded window"),
                touchesWorldState: true, isReversible: true,
                apply: { model in
                    model.reset()
                    return nil
                }))
        }
        // No "is it already playing?" gate: the preview states the target state, and
        // a command that turns out to be a no-op is better than one that silently
        // reports "nothing matched".
        if lower.contains("pause") || lower.contains("stop") || lower.contains("freeze") {
            used.formUnion(["pause", "stop", "freeze"])
            steps.append(Step(
                operation: PlannedOperation(label: "pause the simulation",
                                            detail: context.isPlaying ? nil : "already paused"),
                touchesWorldState: false, isReversible: true,
                apply: { model in
                    let previous = model.isPlaying
                    model.isPlaying = false
                    return { model.isPlaying = previous }
                }))
        } else if lower.contains("play") || lower.contains("run") || lower.contains("start")
                    || lower.contains("resume") {
            used.formUnion(["play", "run", "start", "resume"])
            steps.append(Step(
                operation: PlannedOperation(label: "start the simulation",
                                            detail: context.isPlaying ? "already running" : nil),
                touchesWorldState: false, isReversible: true,
                apply: { model in
                    let previous = model.isPlaying
                    if model.isScrubbing { model.resumeLive() }
                    model.isPlaying = true
                    return { model.isPlaying = previous }
                }))
        }
        // Needs an explicit "one"/"single"/"once" — a bare "frame" belongs to
        // "show link frames", which is a display toggle, not a transport command.
        if lower.contains("single step") || lower.contains("one step")
            || lower.contains("step once") || lower.contains("one frame")
            || lower.contains("single frame") {
            used.formUnion(["frame", "single", "once", "one", "step"])
            steps.append(Step(
                operation: PlannedOperation(label: "advance a single timestep", detail: nil),
                touchesWorldState: true, isReversible: true,
                apply: { model in
                    model.stepOnce()
                    return nil
                }))
        }
    }

    private func appendSpeed(_ lower: String, _ words: [String], _ used: inout Set<String>,
                             _ steps: inout [Step]) {
        var scale: Double?
        if lower.contains("half speed") || lower.contains("slow motion") { scale = 0.5 }
        if lower.contains("quarter speed") { scale = 0.25 }
        if lower.contains("double speed") { scale = 2 }
        if lower.contains("real time") || lower.contains("normal speed") { scale = 1 }
        // "2x", "0.5x"
        for word in words where word.hasSuffix("x") {
            if let value = Double(word.dropLast()) { scale = value }
        }
        if scale == nil, lower.contains("speed"), let value = firstNumber(words) { scale = value }
        guard let target = scale else { return }
        used.formUnion(["speed", "half", "quarter", "double", "slow", "motion", "real", "time",
                        "normal", "x"])
        let clamped = min(max(target, 0.05), 8)
        steps.append(Step(
            operation: PlannedOperation(
                label: String(format: "run at %.2fx wall-clock speed", clamped), detail: nil),
            touchesWorldState: false, isReversible: true,
            apply: { model in
                let previous = model.timeScale
                model.timeScale = clamped
                return { model.timeScale = previous }
            }))
    }

    private func appendDisplay(_ lower: String, _ used: inout Set<String>,
                               _ steps: inout [Step]) {
        // "hide"/"off"/"without" flip the sense; anything else is "show".
        let off = lower.contains("hide") || lower.contains(" off") || lower.contains("disable")
            || lower.contains("without") || lower.contains("turn off")
        let on = !off

        func toggle(_ keyword: [String], label: String,
                    path: @escaping @MainActor (StudioModel) -> Void,
                    restore: @escaping @MainActor (StudioModel, Bool) -> Void,
                    read: @escaping @MainActor (StudioModel) -> Bool) {
            guard keyword.contains(where: { lower.contains($0) }) else { return }
            used.formUnion(keyword.flatMap { $0.split(separator: " ").map(String.init) })
            used.formUnion(["show", "hide", "draw", "display", "off", "on"])
            steps.append(Step(
                operation: PlannedOperation(label: "\(on ? "show" : "hide") \(label)", detail: nil),
                touchesWorldState: false, isReversible: true,
                apply: { model in
                    let previous = read(model)
                    path(model)
                    return { restore(model, previous) }
                }))
        }

        toggle(["grid"], label: "the ground grid",
               path: { $0.settings.showGrid = on },
               restore: { $0.settings.showGrid = $1 },
               read: { $0.settings.showGrid })
        toggle(["contact"], label: "contact points and forces",
               path: { $0.settings.showContacts = on },
               restore: { $0.settings.showContacts = $1 },
               read: { $0.settings.showContacts })
        toggle(["collision"], label: "collision shapes",
               path: { $0.settings.showCollisionGeometry = on },
               restore: { $0.settings.showCollisionGeometry = $1 },
               read: { $0.settings.showCollisionGeometry })
        toggle(["wireframe"], label: "geometry as wireframe",
               path: { $0.settings.wireframe = on },
               restore: { $0.settings.wireframe = $1 },
               read: { $0.settings.wireframe })
        toggle(["trail"], label: "link trails",
               path: { $0.settings.showTrails = on },
               restore: { $0.settings.showTrails = $1 },
               read: { $0.settings.showTrails })
        toggle(["link frame", "frames", "axes"], label: "per-link axes",
               path: { $0.settings.showLinkFrames = on },
               restore: { $0.settings.showLinkFrames = $1 },
               read: { $0.settings.showLinkFrames })
    }

    private func appendTheme(_ lower: String, _ used: inout Set<String>, _ steps: inout [Step],
                             context: IntentContext) {
        let wantsDark = lower.contains("dark")
        let wantsLight = lower.contains("light")
        guard wantsDark != wantsLight else { return }
        guard lower.contains("theme") || lower.contains("mode") || lower.contains("appearance")
        else { return }
        used.formUnion(["dark", "light", "theme", "mode", "appearance", "switch"])
        let target = wantsDark
        steps.append(Step(
            operation: PlannedOperation(
                label: "switch to the \(target ? "dark" : "light") theme",
                detail: target == context.isDark ? "already using it" : "viewport and interface"),
            touchesWorldState: false, isReversible: true,
            apply: { model in
                let previous = model.isDark
                model.isDark = target
                model.applyAppearance()
                return {
                    model.isDark = previous
                    model.applyAppearance()
                }
            }))
    }

    private func appendScene(_ lower: String, _ used: inout Set<String>, _ steps: inout [Step],
                             context: IntentContext) {
        let verbs = ["load", "open", "switch to", "bring up"]
        guard verbs.contains(where: { lower.contains($0) }) else { return }
        // Longest title first so "cart-pole" wins over a scene merely called "cart".
        let candidates = context.scenes.sorted { $0.title.count > $1.title.count }
        guard let scene = candidates.first(where: {
            lower.contains($0.title.lowercased()) || lower.contains($0.id.lowercased())
        }) else { return }
        used.formUnion(["load", "open", "switch", "bring", "up"])
        used.formUnion(tokenise(scene.title.lowercased()))
        steps.append(Step(
            operation: PlannedOperation(
                label: "load the \(scene.title) scene",
                detail: "replaces the current model — this one cannot be undone"),
            touchesWorldState: true, isReversible: false,
            apply: { model in
                model.load(sceneIdentifier: scene.id)
                return nil
            }))
    }

    private func appendPlot(_ lower: String, _ used: inout Set<String>, _ steps: inout [Step],
                            context: IntentContext) {
        let verbs = ["plot", "graph", "chart", "track"]
        guard verbs.contains(where: { lower.contains($0) }) else { return }
        // Match on the channel's words rather than its full label, because labels
        // carry units the user will not type ("step time (ms)").
        let scored = context.channels.map { channel -> (String, Int) in
            let tokens = tokenise(channel.lowercased()).filter { !stopWords.contains($0) }
            let hits = tokens.filter { $0.count > 1 && lower.contains($0) }.count
            return (channel, hits)
        }
        guard let best = scored.max(by: { $0.1 < $1.1 }), best.1 > 0 else { return }
        used.formUnion(["plot", "graph", "chart", "track"])
        used.formUnion(tokenise(best.0.lowercased()))
        let label = best.0
        steps.append(Step(
            operation: PlannedOperation(label: "plot \(label)",
                                        detail: "adds a channel to the telemetry strip"),
            touchesWorldState: false, isReversible: true,
            apply: { model in
                guard let channel = model.availableChannels.first(where: { $0.label == label })
                else { return nil }
                let alreadyPlotted = model.series.contains { $0.channel == channel }
                model.addPlot(channel)
                guard !alreadyPlotted else { return nil }
                return {
                    if let added = model.series.first(where: { $0.channel == channel }) {
                        model.removePlot(added.id)
                    }
                }
            }))
    }

    // MARK: Text helpers

    private func tokenise(_ text: String) -> [String] {
        text.split(whereSeparator: { character in
            !character.isLetter && !character.isNumber && character != "." && character != "-"
        })
        .map(String.init)
        .filter { !$0.isEmpty }
    }

    private func firstNumber(_ words: [String]) -> Double? {
        for word in words {
            if let value = Double(word) { return value }
            // "2ms", "60x" — strip a trailing unit and try again.
            let digits = word.prefix { $0.isNumber || $0 == "." || $0 == "-" }
            if digits.count == word.count { continue }
            if !digits.isEmpty, let value = Double(digits) { return value }
        }
        return nil
    }
}

// MARK: - History

struct AppliedCommand: Identifiable {
    let id = UUID()
    var text: String
    var summary: String
    var appliedAt: Date
    var isUndone: Bool
    var undo: IntentUndo?
}

// MARK: - Surface

/// Natural-language scene control with a mandatory preview step.
///
/// Embed in the palette: `AskKinetic(model: model, presentation: .palette) { dismiss() }`
/// Use as a panel:      `AskKinetic(model: model)`
@MainActor
struct AskKinetic: View {
    enum Presentation {
        case panel
        case palette
    }

    @Environment(\.studioTheme) private var theme
    @ObservedObject var model: StudioModel

    private let interpreter: any SceneIntentInterpreting
    private let presentation: Presentation
    private let onDismiss: (() -> Void)?

    init(model: StudioModel,
         interpreter: any SceneIntentInterpreting = PhraseIntentInterpreter(),
         presentation: Presentation = .panel,
         onDismiss: (() -> Void)? = nil) {
        self.model = model
        self.interpreter = interpreter
        self.presentation = presentation
        self.onDismiss = onDismiss
    }

    @State private var text = ""
    @State private var preview: IntentPreview?
    @State private var suggestions: [String] = []
    @State private var history: [AppliedCommand] = []
    @FocusState private var fieldFocused: Bool

    private var context: IntentContext {
        IntentContext(scenes: SceneLibrary.all.map { SceneOption(id: $0.id, title: $0.title) },
                      channels: model.availableChannels.map { $0.label },
                      isPlaying: model.isPlaying,
                      isDark: model.isDark)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if presentation == .panel {
                SectionLabel(text: "Ask Kinetic", trailing: interpreter.engineName)
            }
            field
                .padding(.horizontal, Metric.gutter)
                .padding(.top, presentation == .palette ? Metric.gutter : 2)

            if !suggestions.isEmpty && preview == nil {
                suggestionList
            }

            if let preview {
                previewCard(preview)
            } else if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                noMatchCard
            }

            if presentation == .panel {
                PanelDivider()
                    .padding(.top, 10)
                historySection
            } else if !history.isEmpty {
                historySection
            }
        }
        .frame(maxWidth: presentation == .palette ? 560 : .infinity, alignment: .leading)
        .background(surfaceChrome)
        .onAppear {
            suggestions = interpreter.suggestions(for: text, context: context)
            if presentation == .palette { fieldFocused = true }
        }
        .onExitCommand { onDismiss?() }
    }

    @ViewBuilder
    private var surfaceChrome: some View {
        if presentation == .palette {
            // Floating chrome gets glass; a docked panel matches the flat surfaces
            // around it, because a pane of glass inside a pane of glass reads as neither.
            if #available(macOS 26.0, *) {
                RoundedRectangle(cornerRadius: Metric.radiusLarge, style: .continuous)
                    .fill(.clear)
                    .glassEffect(.regular,
                                 in: RoundedRectangle(cornerRadius: Metric.radiusLarge,
                                                      style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: Metric.radiusLarge, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: Metric.radiusLarge, style: .continuous)
                        .stroke(theme.border, lineWidth: 1))
            }
        } else {
            theme.background
        }
    }

    // MARK: Field

    /// A search field built here rather than borrowed, so this surface has no
    /// dependency on chrome that lives elsewhere.
    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(fieldFocused ? theme.accent : theme.tertiary)

            TextField("Describe a change — \"turn off gravity\"", text: $text)
                .textFieldStyle(.plain)
                .font(Typo.body)
                .foregroundStyle(theme.text)
                .focused($fieldFocused)
                .onSubmit { apply() }
                .onChange(of: text) { _, newValue in
                    // Parsing is pure: typing previews, it never applies.
                    preview = interpreter.parse(newValue, context: context)
                    suggestions = interpreter.suggestions(for: newValue, context: context)
                }

            if !text.isEmpty {
                Button {
                    clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.tertiary)
                }
                .buttonStyle(.plain)
            } else {
                Text("⏎")
                    .font(Typo.monoSmall)
                    .foregroundStyle(theme.tertiary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(theme.border.opacity(0.5)))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(fieldChrome)
        .contentShape(RoundedRectangle(cornerRadius: Metric.radius, style: .continuous))
        .onTapGesture { fieldFocused = true }
    }

    @ViewBuilder
    private var fieldChrome: some View {
        let shape = RoundedRectangle(cornerRadius: Metric.radius, style: .continuous)
        if #available(macOS 26.0, *) {
            shape.fill(.clear)
                .glassEffect(.regular.tint(fieldFocused ? theme.accent.opacity(0.18) : .clear)
                    .interactive(), in: shape)
        } else {
            shape.fill(theme.surface)
                .overlay(shape.stroke(fieldFocused ? theme.accent : theme.border, lineWidth: 1))
                .background(.ultraThinMaterial, in: shape)
        }
    }

    // MARK: Suggestions

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(suggestions, id: \.self) { suggestion in
                Button {
                    text = suggestion
                    preview = interpreter.parse(suggestion, context: context)
                    suggestions = []
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.system(size: 9))
                            .foregroundStyle(theme.tertiary)
                        Text(suggestion)
                            .font(Typo.small)
                            .foregroundStyle(theme.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Metric.gutter)
                    .frame(height: 22)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    // MARK: Preview

    private func previewCard(_ preview: IntentPreview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(preview.summary)
                    .font(Typo.body.weight(.medium))
                    .foregroundStyle(theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                Chip(text: String(format: "%.0f%% match", preview.confidence * 100),
                     tone: confidenceTone(preview.confidence))
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(preview.operations) { operation in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 4))
                            .foregroundStyle(theme.accent)
                            .padding(.top, 5)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(operation.label)
                                .font(Typo.small)
                                .foregroundStyle(theme.text)
                                .fixedSize(horizontal: false, vertical: true)
                            if let detail = operation.detail {
                                Text(detail)
                                    .font(Typo.monoSmall)
                                    .foregroundStyle(theme.tertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }

            if !preview.unmatched.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.warning)
                    Text("Ignored: " + preview.unmatched.joined(separator: ", "))
                        .font(Typo.small)
                        .foregroundStyle(theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }

            Text(preview.notes + " " + interpreter.disclaimer)
                .font(Typo.monoSmall)
                .foregroundStyle(theme.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if !preview.isReversible {
                Text("This one cannot be undone from here.")
                    .font(Typo.monoSmall)
                    .foregroundStyle(Palette.warning)
            }

            HStack(spacing: 6) {
                ToolbarButton(systemImage: "checkmark", label: "Apply", isActive: true) {
                    apply()
                }
                ToolbarButton(systemImage: "xmark", label: "Cancel") { clear() }
                Spacer(minLength: 0)
                Text("nothing has changed yet")
                    .font(Typo.monoSmall)
                    .foregroundStyle(theme.tertiary)
            }
        }
        .padding(Metric.gutter)
        .background(RoundedRectangle(cornerRadius: Metric.radius).fill(theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Metric.radius)
            .stroke(theme.border, lineWidth: 1))
        .padding(.horizontal, Metric.gutter)
        .padding(.top, 8)
    }

    private var noMatchCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Nothing matched")
                .font(Typo.small.weight(.medium))
                .foregroundStyle(theme.text)
            Text("The matcher looks for known phrases — gravity, timestep, solver iterations, "
                 + "transport, speed, display toggles, themes, scenes and channels. Try one of "
                 + "the suggestions, or rephrase using those words.")
                .font(Typo.small)
                .foregroundStyle(theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Metric.gutter)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Metric.radius).fill(theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Metric.radius)
            .stroke(theme.borderSubtle, lineWidth: 1))
        .padding(.horizontal, Metric.gutter)
        .padding(.top, 8)
    }

    private func confidenceTone(_ confidence: Double) -> Color {
        if confidence >= 0.8 { return Palette.success }
        if confidence >= 0.6 { return theme.accent }
        return Palette.warning
    }

    // MARK: History

    @ViewBuilder
    private var historySection: some View {
        if history.isEmpty {
            if presentation == .panel {
                Text("Applied commands are listed here, with an undo where the change can be "
                     + "taken back.")
                    .font(Typo.small)
                    .foregroundStyle(theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Metric.gutter)
                    .padding(.vertical, 10)
            }
        } else {
            SectionLabel(text: "Applied", trailing: "\(history.count)")
            VStack(spacing: 1) {
                ForEach(history.prefix(presentation == .palette ? 3 : 20)) { entry in
                    historyRow(entry)
                }
            }
            .padding(.bottom, 10)
        }
    }

    private func historyRow(_ entry: AppliedCommand) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.text)
                    .font(Typo.small.weight(.medium))
                    .foregroundStyle(entry.isUndone ? theme.tertiary : theme.text)
                    .strikethrough(entry.isUndone, color: theme.tertiary)
                    .lineLimit(1)
                Text(entry.summary)
                    .font(Typo.monoSmall)
                    .foregroundStyle(theme.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            if entry.undo != nil && !entry.isUndone {
                ToolbarButton(systemImage: "arrow.uturn.backward", label: "Undo") {
                    undo(entry)
                }
            } else {
                Text(entry.isUndone ? "undone" : "not reversible")
                    .font(Typo.monoSmall)
                    .foregroundStyle(theme.tertiary)
            }
        }
        .padding(.horizontal, Metric.gutter)
        .padding(.vertical, 6)
    }

    // MARK: Actions

    private func apply() {
        guard let preview else { return }
        // Snapshot first: state is the one thing an operation cannot hand back.
        let snapshot = preview.touchesWorldState ? model.world.saveState() : nil
        let outcome = preview.perform(model)
        // The world is a reference type, so a mutation through it does not publish
        // on its own.
        model.objectWillChange.send()

        var undo: (@MainActor () -> Void)?
        if preview.isReversible {
            let restore = outcome.undo
            undo = {
                restore?()
                if let snapshot {
                    model.world.loadState(snapshot)
                    model.world.forward()
                }
                model.objectWillChange.send()
            }
        }

        history.insert(AppliedCommand(text: preview.command, summary: outcome.message,
                                      appliedAt: Date(), isUndone: false, undo: undo),
                       at: 0)
        if history.count > 40 { history.removeLast(history.count - 40) }
        model.log("ask: \(outcome.message)", .success)
        clear()
        if presentation == .palette { onDismiss?() }
    }

    private func undo(_ entry: AppliedCommand) {
        guard let action = entry.undo,
              let index = history.firstIndex(where: { $0.id == entry.id }) else { return }
        action()
        history[index].isUndone = true
        history[index].undo = nil
        model.log("ask: undid \"\(entry.text)\"", .info)
    }

    private func clear() {
        text = ""
        preview = nil
        suggestions = interpreter.suggestions(for: "", context: context)
    }
}
