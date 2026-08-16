//
//  IntentParser.swift
//  KineticML
//
//  Natural language -> ScenePlan.
//
//  WHY THE DETERMINISTIC PATH IS PRIMARY
//  -------------------------------------
//  Kinetic sells reproducibility: the same scene, the same seed and the same
//  solver settings must give the same trajectory on every machine, forever.
//  A language model in the hot path breaks that promise in three separate ways.
//  It is non-deterministic (the same sentence can yield a different plan next
//  week), it is unavailable offline and in CI, and it is unauditable -- a
//  reviewer cannot diff "what the words meant" against anything. So the grammar
//  below is the default and the only path that needs to work: a hand-written
//  tokeniser with real units, a fixed rule order, and a confidence score
//  derived from how much of the sentence it actually consumed. The model
//  backend is opt-in, is consulted only when the grammar's confidence is low,
//  and can only ever produce a ScenePlan -- the same reviewable, seeded,
//  serialisable object the grammar produces. Nothing reaches the World that a
//  user has not been shown first.
//

import Foundation
import Kinetic

// MARK: - Result

public struct ParsedIntent: Codable, Hashable, Sendable {
    public let plan: ScenePlan
    /// 0...1. How much of the input the grammar actually accounted for.
    public let confidence: Double
    /// Meaningful words the parser could not place. Never silently dropped.
    public let unmatched: [String]

    public init(plan: ScenePlan, confidence: Double, unmatched: [String]) {
        self.plan = plan
        self.confidence = min(max(confidence, 0), 1)
        self.unmatched = unmatched
    }
}

// MARK: - Units

enum Unit: String, Hashable, Sendable {
    case millimetre, centimetre, metre, kilometre
    case millisecond, second, minute
    case hertz, kilohertz
    case degree, radian
    case kilogram, densitySI
    case newtonSecond
    case acceleration

    var lengthInMetres: Double? {
        switch self {
        case .millimetre: return 0.001
        case .centimetre: return 0.01
        case .metre: return 1
        case .kilometre: return 1000
        default: return nil
        }
    }

    var timeInSeconds: Double? {
        switch self {
        case .millisecond: return 0.001
        case .second: return 1
        case .minute: return 60
        default: return nil
        }
    }

    var isFrequency: Bool { self == .hertz || self == .kilohertz }

    var angleInRadians: Double? {
        switch self {
        case .degree: return Double.pi / 180
        case .radian: return 1
        default: return nil
        }
    }

    static let table: [String: Unit] = [
        "mm": .millimetre, "millimeter": .millimetre, "millimeters": .millimetre,
        "millimetre": .millimetre, "millimetres": .millimetre,
        "cm": .centimetre, "centimeter": .centimetre, "centimeters": .centimetre,
        "centimetre": .centimetre, "centimetres": .centimetre,
        "m": .metre, "meter": .metre, "meters": .metre, "metre": .metre, "metres": .metre,
        "km": .kilometre, "kilometer": .kilometre, "kilometre": .kilometre,
        "ms": .millisecond, "msec": .millisecond, "millisecond": .millisecond,
        "milliseconds": .millisecond,
        "s": .second, "sec": .second, "secs": .second, "second": .second, "seconds": .second,
        "min": .minute, "mins": .minute, "minute": .minute, "minutes": .minute,
        "hz": .hertz, "hertz": .hertz, "khz": .kilohertz, "kilohertz": .kilohertz,
        "deg": .degree, "degree": .degree, "degrees": .degree,
        "rad": .radian, "radian": .radian, "radians": .radian,
        "kg": .kilogram,
        "kg/m3": .densitySI, "kg/m^3": .densitySI, "kgm3": .densitySI,
        "n": .newtonSecond, "ns": .newtonSecond, "newton": .newtonSecond,
        "newtons": .newtonSecond, "n-s": .newtonSecond,
        "m/s": .acceleration, "m/s2": .acceleration, "m/s^2": .acceleration,
    ]
}

// MARK: - Lexer

struct Lexeme {
    var text: String
    var number: Double?
    var unit: Unit?
    /// Folded into a neighbour: a unit word, or the tail of a compound numeral.
    var absorbed = false
    /// Claimed by a rule.
    var consumed = false

    var isNumber: Bool { number != nil }
}

/// Word -> value. Only the forms people actually type at a command palette.
let numberWords: [String: Double] = [
    "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
    "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
    "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17,
    "eighteen": 18, "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40,
    "fourty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80,
    "ninety": 90, "hundred": 100, "half": 0.5, "quarter": 0.25,
    "dozen": 12, "couple": 2, "few": 3, "several": 4, "pair": 2, "handful": 5,
    "single": 1, "twice": 2,
]

let tensWords: Set<String> = ["twenty", "thirty", "forty", "fourty", "fifty", "sixty",
                              "seventy", "eighty", "ninety"]

/// Words that carry no scene meaning; excluded from the confidence denominator
/// so "please add five boxes for me" is not punished for being polite.
let stopWords: Set<String> = [
    "the", "a", "an", "of", "to", "in", "into", "on", "and", "then", "please",
    "some", "it", "its", "that", "this", "there", "be", "is", "are", "am", "i",
    "want", "would", "like", "lets", "let", "us", "me", "my", "ok", "okay",
    "plz", "just", "also", "about", "new", "more", "each", "other",
    "onto", "top", "here", "now", "can", "you", "could", "kindly",
    "them", "these", "those", "one", "s",
]

enum Lexer {
    /// Normalises, splits, peels glued numbers, folds numerals and attaches units.
    static func lex(_ raw: String) -> [Lexeme] {
        var cleaned = ""
        cleaned.reserveCapacity(raw.count)
        for character in raw.lowercased() {
            if character.isLetter || character.isNumber {
                cleaned.append(character)
            } else if "._-+/^".contains(character) {
                cleaned.append(character)
            } else {
                cleaned.append(" ")
            }
        }

        var items: [Lexeme] = []
        for chunk in cleaned.split(separator: " ") {
            appendPieces(String(chunk), into: &items)
        }
        foldNumerals(&items)
        attachUnits(&items)
        return items
    }

    /// Splits "10cm" into 10 + cm and "4x4" into 4 + x + 4, while leaving
    /// alpha-leading tokens such as "rk4" and "m/s^2" whole.
    private static func appendPieces(_ chunk: String, into items: inout [Lexeme]) {
        var rest = Substring(chunk)
        while !rest.isEmpty {
            let startsNumeric = rest.first.map { $0.isNumber } ?? false
            let hasSign = rest.first == "-" || rest.first == "+"
            let signedNumeric = hasSign && (rest.dropFirst().first.map { $0.isNumber } ?? false)

            if startsNumeric || signedNumeric {
                var end = rest.startIndex
                if signedNumeric { end = rest.index(after: end) }
                var sawDot = false
                while end < rest.endIndex {
                    let character = rest[end]
                    if character.isNumber {
                        end = rest.index(after: end)
                    } else if character == "." && !sawDot
                                && rest.index(after: end) < rest.endIndex
                                && rest[rest.index(after: end)].isNumber {
                        sawDot = true
                        end = rest.index(after: end)
                    } else {
                        break
                    }
                }
                let literal = String(rest[rest.startIndex..<end])
                items.append(Lexeme(text: literal, number: Double(literal)))
                rest = rest[end...]
                // "-" left dangling by "3.7-" style typos is dropped below.
                if rest.first == "-" || rest.first == "." { rest = rest.dropFirst() }
            } else {
                var token = String(rest)
                rest = rest[rest.endIndex...]
                while token.hasSuffix(".") || token.hasSuffix("-") || token.hasSuffix("_") {
                    token.removeLast()
                }
                guard !token.isEmpty else { continue }
                // "x4" / "x10" as grid shorthand: split the multiplier out.
                if token.count > 1, token.hasPrefix("x"),
                   let value = Double(token.dropFirst()) {
                    items.append(Lexeme(text: "x", number: nil))
                    items.append(Lexeme(text: String(token.dropFirst()), number: value))
                    continue
                }
                items.append(Lexeme(text: token, number: numberWords[token]))
            }
        }
    }

    /// "twenty five" -> 25, "two dozen" -> 24, "half a dozen" -> 6.
    private static func foldNumerals(_ items: inout [Lexeme]) {
        var i = 0
        while i < items.count {
            guard let value = items[i].number, !items[i].absorbed else {
                i += 1
                continue
            }
            // Skip an intervening article for "half a dozen".
            var j = i + 1
            if j < items.count && (items[j].text == "a" || items[j].text == "an") { j += 1 }
            guard j < items.count, let nextValue = items[j].number else {
                i += 1
                continue
            }
            if items[j].text == "dozen" || items[j].text == "hundred" {
                items[i].number = value * nextValue
                items[i].text = "\(value * nextValue)"
                for k in (i + 1)...j { items[k].absorbed = true }
            } else if tensWords.contains(items[i].text) && nextValue >= 1 && nextValue <= 9
                        && j == i + 1 {
                items[i].number = value + nextValue
                items[i].text = "\(value + nextValue)"
                items[j].absorbed = true
            }
            i += 1
        }
    }

    /// A unit word only counts as a unit when it trails a number, so the "m" in
    /// "2 m" is metres while a stray "m" stays an unknown word.
    private static func attachUnits(_ items: inout [Lexeme]) {
        var i = 0
        while i < items.count {
            guard items[i].number != nil, !items[i].absorbed else {
                i += 1
                continue
            }
            var j = i + 1
            while j < items.count && items[j].absorbed { j += 1 }
            if j < items.count, items[j].number == nil,
               let unit = Unit.table[items[j].text] {
                items[i].unit = unit
                items[j].absorbed = true
            }
            i += 1
        }
    }
}

// MARK: - Token stream helpers

struct TokenStream {
    var items: [Lexeme]

    init(_ text: String) {
        items = Lexer.lex(text)
    }

    var count: Int { items.count }

    func live(_ index: Int) -> Bool {
        index >= 0 && index < items.count && !items[index].consumed && !items[index].absorbed
    }

    mutating func consume(_ indices: Int...) {
        consume(indices)
    }

    mutating func consume(_ indices: [Int]) {
        for index in indices where index >= 0 && index < items.count {
            items[index].consumed = true
        }
    }

    func first(of words: Set<String>) -> Int? {
        items.indices.first { live($0) && words.contains(items[$0].text) }
    }

    func all(of words: Set<String>) -> [Int] {
        items.indices.filter { live($0) && words.contains(items[$0].text) }
    }

    func contains(_ words: Set<String>) -> Bool { first(of: words) != nil }

    /// Live numeric tokens, optionally filtered.
    func numbers(where predicate: (Lexeme) -> Bool = { _ in true }) -> [Int] {
        items.indices.filter { live($0) && items[$0].isNumber && predicate(items[$0]) }
    }

    /// Nearest live number to `origin`. `direction` is -1, 0 or +1.
    func nearestNumber(to origin: Int, maxDistance: Int, direction: Int = 0,
                       where predicate: (Lexeme) -> Bool = { _ in true }) -> Int? {
        var best: Int?
        var bestDistance = Int.max
        for index in numbers(where: predicate) {
            let delta = index - origin
            if direction < 0 && delta >= 0 { continue }
            if direction > 0 && delta <= 0 { continue }
            let distance = abs(delta)
            if distance <= maxDistance && distance < bestDistance {
                best = index
                bestDistance = distance
            }
        }
        return best
    }

    // MARK: Typed readers

    /// Length in metres. A bare number is read as metres.
    func metres(at index: Int) -> Double? {
        guard live(index), let value = items[index].number else { return nil }
        guard let unit = items[index].unit else { return value }
        guard let scale = unit.lengthInMetres else { return nil }
        return value * scale
    }

    /// Duration in seconds. A bare number is read as seconds.
    func seconds(at index: Int) -> Double? {
        guard live(index), let value = items[index].number else { return nil }
        guard let unit = items[index].unit else { return value }
        guard let scale = unit.timeInSeconds else { return nil }
        return value * scale
    }

    /// Angle in radians. A bare number is read as radians; "45 degrees" converts.
    func radians(at index: Int) -> Double? {
        guard live(index), let value = items[index].number else { return nil }
        guard let unit = items[index].unit else { return value }
        guard let scale = unit.angleInRadians else { return nil }
        return value * scale
    }

    func hasLengthUnit(_ index: Int) -> Bool {
        guard index >= 0 && index < items.count else { return false }
        return items[index].unit?.lengthInMetres != nil
    }

    func isUnitless(_ index: Int) -> Bool {
        guard index >= 0 && index < items.count else { return false }
        return items[index].unit == nil
    }
}

// MARK: - Vocabulary

enum Vocabulary {
    static let shapeNouns: [String: ShapeSpec.Kind] = [
        "box": .box, "boxes": .box, "cube": .box, "cubes": .box, "crate": .box,
        "crates": .box, "block": .box, "blocks": .box, "brick": .box, "bricks": .box,
        "sphere": .sphere, "spheres": .sphere, "ball": .sphere, "balls": .sphere,
        "marble": .sphere, "marbles": .sphere, "orb": .sphere, "orbs": .sphere,
        "capsule": .capsule, "capsules": .capsule, "pill": .capsule, "pills": .capsule,
        "cylinder": .cylinder, "cylinders": .cylinder, "can": .cylinder, "cans": .cylinder,
        "puck": .cylinder, "pucks": .cylinder, "rod": .cylinder, "rods": .cylinder,
        "body": .box, "bodies": .box, "object": .box, "objects": .box,
        "prop": .box, "props": .box, "thing": .box, "things": .box,
    ]

    static let pluralShapeNouns: Set<String> = [
        "boxes", "cubes", "crates", "blocks", "bricks", "spheres", "balls", "marbles",
        "orbs", "capsules", "pills", "cylinders", "cans", "pucks", "rods", "bodies",
        "objects", "props", "things",
    ]

    static let materials: [String: MaterialSpec] = [
        "icy": .ice, "ice": .ice, "frozen": .ice,
        "slippery": .slippery, "slick": .slippery,
        "frictionless": .frictionless, "smooth": .frictionless,
        "sticky": .sticky, "tacky": .sticky, "gummy": .sticky,
        "bouncy": .bouncy, "springy": .bouncy, "elastic": .bouncy, "trampoline": .bouncy,
        "rubber": .rubber, "rubbery": .rubber, "grippy": .rubber,
        "steel": .steel, "metal": .steel, "metallic": .steel,
        "rough": .rough, "gritty": .rough, "sandpaper": .rough,
        "concrete": MaterialSpec(name: "concrete", friction: 1.0),
        "asphalt": MaterialSpec(name: "asphalt", friction: 1.1),
        "tarmac": MaterialSpec(name: "tarmac", friction: 1.1),
        "grass": MaterialSpec(name: "grass", friction: 0.9),
        "carpet": MaterialSpec(name: "carpet", friction: 1.2),
        "glass": MaterialSpec(name: "glass", friction: 0.3, restitution: 0.15),
        "wood": MaterialSpec(name: "wood", friction: 0.6),
        "wooden": MaterialSpec(name: "wood", friction: 0.6),
    ]

    /// Density in kg/m3 for spoken substances and weights.
    static let densities: [String: Double] = [
        "heavy": 2000, "dense": 3000, "light": 120, "lightweight": 120, "featherlight": 40,
        "steel": 7800, "metal": 7800, "iron": 7870, "lead": 11340, "aluminium": 2700,
        "aluminum": 2700, "wood": 600, "wooden": 600, "plastic": 950, "foam": 60,
        "stone": 2600, "granite": 2700, "concrete": 2400, "ice": 917, "rubber": 1200,
        "glass": 2500, "hollow": 80,
    ]

    static let surfaceNouns: Set<String> = [
        "ground", "floor", "plane", "terrain", "ice", "rink", "tarmac", "asphalt",
        "concrete", "grass", "carpet", "pavement", "slab",
    ]

    static let strongAddVerbs: Set<String> = [
        "add", "drop", "spawn", "create", "throw", "toss", "scatter", "stack",
        "dump", "insert", "generate", "rain", "pour", "sprinkle",
    ]

    static let weakAddVerbs: Set<String> = ["make", "place", "put", "give", "set", "build"]

    static let dropVerbs: Set<String> = ["drop", "throw", "toss", "rain", "dump", "pour", "fall"]

    static let impulseVerbs: Set<String> = [
        "push", "kick", "shove", "nudge", "launch", "punt", "hit", "strike", "whack",
    ]

    static let directions: [String: Vector3] = [
        "forward": Vector3(1, 0, 0), "forwards": Vector3(1, 0, 0), "ahead": Vector3(1, 0, 0),
        "north": Vector3(1, 0, 0),
        "back": Vector3(-1, 0, 0), "backward": Vector3(-1, 0, 0),
        "backwards": Vector3(-1, 0, 0), "south": Vector3(-1, 0, 0),
        "left": Vector3(0, 1, 0), "sideways": Vector3(0, 1, 0), "west": Vector3(0, 1, 0),
        "right": Vector3(0, -1, 0), "east": Vector3(0, -1, 0),
        "up": Vector3(0, 0, 1), "upward": Vector3(0, 0, 1), "upwards": Vector3(0, 0, 1),
        "down": Vector3(0, 0, -1), "downward": Vector3(0, 0, -1), "downwards": Vector3(0, 0, -1),
    ]

    /// Vertical gravity in m/s2 for bodies people name.
    static let gravityPresets: [String: Double] = [
        "earth": -9.81, "terrestrial": -9.81, "normal": -9.81, "standard": -9.81,
        "moon": -1.62, "lunar": -1.62,
        "mars": -3.71, "martian": -3.71,
        "jupiter": -24.79, "venus": -8.87, "mercury": -3.70, "saturn": -10.44,
        "titan": -1.35, "europa": -1.31, "pluto": -0.62, "ceres": -0.27, "sun": -274.0,
        "space": 0, "microgravity": 0, "weightless": 0, "orbit": 0, "iss": 0,
        "zero-g": 0, "zerog": 0, "freefall": 0,
    ]

    /// Scene aliases resolved against SceneLibrary so the two stay in step.
    static let sceneAliases: [String: String] = [
        "stack": "stack", "boxstack": "stack",
        "arm": "arm", "manipulator": "arm", "robot": "arm", "cobot": "arm",
        "quadruped": "quadruped", "dog": "quadruped", "walker": "quadruped",
        "cartpole": "cartpole", "cart": "cartpole", "pole": "cartpole",
        "chain": "chain", "pendulum": "chain",
        "dominoes": "dominoes", "dominos": "dominoes", "domino": "dominoes",
        "mixed": "mixed", "primitives": "mixed", "primitive": "mixed",
    ]

    static let loadVerbs: Set<String> = ["load", "open", "show", "scene", "demo", "example"]
}

// MARK: - Grammar

/// One parse. Rules run in a fixed order and mark the tokens they claim; what
/// is left over becomes `unmatched` and drags the confidence down.
struct Grammar {
    var tokens: TokenStream
    var operations: [SceneOperation] = []
    let seed: UInt64
    /// Shape the sentence talked about, so later rules can target it.
    var subject: ShapeSpec.Kind?
    var addedBodies = false
    var timestep: Double = 1.0 / 500.0

    init(text: String) {
        tokens = TokenStream(text)
        seed = stableSeed(text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))
    }

    mutating func run() {
        parseReset()
        parseLoadScene()
        parseIntegrator()
        parseSolverIterations()
        parseTimestep()
        parseGravity()
        parseRun()
        parseGround()
        parseBodies()
        parseImpulse()
        parseStandaloneMaterial()
        parseTrailingTimestep()
    }

    // MARK: reset

    private mutating func parseReset() {
        guard let index = tokens.first(of: ["reset", "restart", "rewind"]) else { return }
        tokens.consume(index)
        operations.append(.reset)
    }

    // MARK: loadScene

    private mutating func parseLoadScene() {
        let verb = tokens.first(of: Vocabulary.loadVerbs)
        let aliasIndex = tokens.items.indices.first {
            tokens.live($0) && Vocabulary.sceneAliases[tokens.items[$0].text] != nil
        }
        guard let alias = aliasIndex, let id = Vocabulary.sceneAliases[tokens.items[alias].text]
        else { return }

        if verb == nil {
            // Without an explicit verb, only accept an input that is nothing but
            // the scene name -- otherwise "stack 8 boxes" would load a scene.
            let meaningful = tokens.items.indices.filter {
                tokens.live($0) && !stopWords.contains(tokens.items[$0].text)
            }
            guard meaningful == [alias] else { return }
        }

        if let verb { tokens.consume(verb) }
        tokens.consume(alias)
        // "cart pole" spends two words on one scene.
        if alias + 1 < tokens.count, tokens.live(alias + 1),
           Vocabulary.sceneAliases[tokens.items[alias + 1].text] == id {
            tokens.consume(alias + 1)
        }
        operations.append(.loadScene(id))
    }

    // MARK: integrator

    private mutating func parseIntegrator() {
        let names: [String] = [
            "rk4", "runge-kutta", "rungekutta", "runge", "semi-implicit", "semiimplicit",
            "symplectic", "euler", "implicit-fast", "implicitfast", "implicit",
        ]
        guard let index = tokens.items.indices.first(where: { i in
            tokens.live(i) && names.contains(tokens.items[i].text)
        }) else { return }
        guard let integrator = IntegratorNaming.resolve(tokens.items[index].text) else { return }
        // "semi-implicit euler" and "runge-kutta rk4" name the same integrator
        // twice; claim every synonym so none is reported as unmatched.
        tokens.consume(tokens.items.indices.filter { i in
            tokens.live(i) && names.contains(tokens.items[i].text)
                && IntegratorNaming.resolve(tokens.items[i].text) == integrator
        })
        if let use = tokens.first(of: ["use", "using", "switch", "integrator", "integration"]) {
            tokens.consume(use)
        }
        // "runge kutta 4" leaves a stray 4 behind.
        if integrator == .rungeKutta4, index + 1 < tokens.count, tokens.live(index + 1),
           tokens.items[index + 1].number == 4 {
            tokens.consume(index + 1)
        }
        operations.append(.setIntegrator(IntegratorNaming.name(integrator)))
    }

    // MARK: solver iterations

    private mutating func parseSolverIterations() {
        let triggers: Set<String> = ["iterations", "iteration", "iters", "iter"]
        let solver = tokens.first(of: ["solver", "solve"])
        guard let trigger = tokens.first(of: triggers) ?? solver else { return }
        let candidate = tokens.nearestNumber(to: trigger, maxDistance: 3, direction: 0) {
            $0.unit == nil
        }
        guard let numberIndex = candidate, let value = tokens.items[numberIndex].number,
              value >= 1, value <= 1000 else { return }
        tokens.consume(trigger, numberIndex)
        if let solver, solver != trigger { tokens.consume(solver) }
        if let word = tokens.first(of: triggers) { tokens.consume(word) }
        operations.append(.setSolverIterations(Int(value.rounded())))
    }

    // MARK: timestep

    private mutating func parseTimestep() {
        // A frequency is unambiguous: nothing else in this grammar is in hertz.
        if let index = tokens.items.indices.first(where: { i in
            tokens.live(i) && (tokens.items[i].unit?.isFrequency ?? false)
        }), let value = tokens.items[index].number, value > 0 {
            let hz = tokens.items[index].unit == .kilohertz ? value * 1000 : value
            tokens.consume(index)
            consumeNearby(["at", "rate", "run", "step", "stepping", "sim", "simulate"], of: index)
            timestep = 1 / hz
            operations.append(.setTimestep(timestep))
            return
        }

        let triggers: Set<String> = ["timestep", "timesteps", "dt", "substep", "h"]
        var trigger = tokens.first(of: triggers)
        if trigger == nil, let time = tokens.first(of: ["time"]),
           time + 1 < tokens.count, tokens.items[time + 1].text == "step" {
            tokens.consume(time)
            trigger = time + 1
        }
        guard let triggerIndex = trigger else { return }
        guard let numberIndex = tokens.nearestNumber(to: triggerIndex, maxDistance: 3),
              let value = tokens.seconds(at: numberIndex), value > 0 else { return }
        tokens.consume(triggerIndex, numberIndex)
        consumeNearby(["set", "to", "of"], of: triggerIndex)
        timestep = value
        operations.append(.setTimestep(value))
    }

    /// Late fallback: a bare millisecond quantity with nothing else claiming it
    /// is a timestep. Runs after `parseRun` so "run for 500 ms" stays a run.
    private mutating func parseTrailingTimestep() {
        guard !operations.contains(where: { if case .setTimestep = $0 { return true }
                                            return false }) else { return }
        guard let index = tokens.items.indices.first(where: { i in
            tokens.live(i) && tokens.items[i].unit == .millisecond
        }), let value = tokens.seconds(at: index), value > 0, value <= 0.1 else { return }
        tokens.consume(index)
        timestep = value
        operations.append(.setTimestep(value))
    }

    // MARK: gravity

    private let gravityFiller: Set<String> = ["set", "make", "change", "switch", "use",
                                              "like", "on", "under"]

    private mutating func parseGravity() {
        let gravityWord = tokens.first(of: ["gravity", "gravitational", "grav"])
        let presetIndex = tokens.items.indices.first {
            tokens.live($0) && Vocabulary.gravityPresets[tokens.items[$0].text] != nil
        }

        if let word = gravityWord {
            // Explicit components: up to three numbers walking forward, with
            // articles and "to"/"=" allowed in between.
            var components: [Double] = []
            var indices: [Int] = []
            var i = word + 1
            while i < tokens.count && components.count < 3 {
                if tokens.items[i].absorbed { i += 1; continue }
                if let value = tokens.items[i].number, tokens.live(i) {
                    components.append(value)
                    indices.append(i)
                } else if stopWords.contains(tokens.items[i].text)
                            || tokens.items[i].text == "set" {
                    // keep walking
                } else if components.isEmpty {
                    break
                } else {
                    break
                }
                i += 1
            }

            if components.count == 3 {
                tokens.consume(word)
                tokens.consume(indices)
                consumeNearby(gravityFiller, of: word)
                operations.append(.setGravity(Vector3(components[0], components[1],
                                                      components[2])))
                return
            }
            if components.count == 1, presetIndex == nil {
                tokens.consume(word)
                tokens.consume(indices)
                consumeNearby(gravityFiller, of: word)
                // "gravity 9.81" and "gravity -9.81" both mean downwards.
                operations.append(.setGravity(Vector3(0, 0, -abs(components[0]))))
                return
            }
            if let preset = presetIndex,
               let value = Vocabulary.gravityPresets[tokens.items[preset].text] {
                tokens.consume(word, preset)
                consumeNearby(gravityFiller, of: word)
                consumeNearby(gravityFiller, of: preset)
                operations.append(.setGravity(Vector3(0, 0, value)))
                return
            }
            if let off = tokens.first(of: ["off", "none", "no", "disable", "disabled"]) {
                tokens.consume(off, word)
                operations.append(.setGravity(Vector3(0, 0, 0)))
                return
            }
            return
        }

        // "on the moon" with no "gravity" word: the planet names are unambiguous
        // here because nothing else in the grammar uses them.
        if let preset = presetIndex,
           let value = Vocabulary.gravityPresets[tokens.items[preset].text] {
            tokens.consume(preset)
            operations.append(.setGravity(Vector3(0, 0, value)))
        }
    }

    // MARK: run

    private mutating func parseRun() {
        let verbs: Set<String> = ["run", "simulate", "play", "advance", "sim", "step"]
        guard let verb = tokens.first(of: verbs) else { return }
        guard let numberIndex = tokens.nearestNumber(to: verb, maxDistance: 4, direction: 1)
        else { return }

        // "run 500 steps" counts steps, everything else counts time.
        var isSteps = false
        var after = numberIndex + 1
        while after < tokens.count && tokens.items[after].absorbed { after += 1 }
        if after < tokens.count, ["steps", "step", "ticks", "tick"].contains(tokens.items[after].text) {
            isSteps = true
        }

        let seconds: Double
        if isSteps {
            guard let steps = tokens.items[numberIndex].number, steps > 0 else { return }
            seconds = steps * timestep
            tokens.consume(after)
        } else {
            guard let value = tokens.seconds(at: numberIndex), value > 0 else { return }
            seconds = value
        }
        tokens.consume(verb, numberIndex)
        consumeNearby(["for", "over"], of: verb)
        operations.append(.run(seconds: seconds))
    }

    // MARK: ground

    private mutating func parseGround() {
        guard let surface = tokens.items.indices.first(where: { i in
            tokens.live(i) && Vocabulary.surfaceNouns.contains(tokens.items[i].text)
        }) else { return }

        // "5 ice cubes" -- the surface word is an adjective on a shape noun.
        var next = surface + 1
        while next < tokens.count && tokens.items[next].absorbed { next += 1 }
        if next < tokens.count, Vocabulary.shapeNouns[tokens.items[next].text] != nil { return }

        // "no ground", "without a floor".
        if surface > 0 {
            let previous = tokens.items[max(surface - 1, 0)].text
            if previous == "no" || previous == "without" || previous == "remove" { return }
        }

        var material = Vocabulary.materials[tokens.items[surface].text] ?? MaterialSpec.default
        tokens.consume(surface)

        // Nearest material adjective anywhere still unclaimed.
        if let adjective = tokens.items.indices.first(where: { i in
            tokens.live(i) && Vocabulary.materials[tokens.items[i].text] != nil
        }), let spec = Vocabulary.materials[tokens.items[adjective].text] {
            material = spec
            tokens.consume(adjective)
        }

        // "ground friction 0.3" wins over any adjective.
        if let frictionWord = tokens.first(of: ["friction", "mu"]),
           let numberIndex = tokens.nearestNumber(to: frictionWord, maxDistance: 3),
           let value = tokens.items[numberIndex].number, value >= 0 {
            material = MaterialSpec(name: "custom", friction: value,
                                    restitution: material.restitution)
            tokens.consume(frictionWord, numberIndex)
        }

        consumeNearby(["make", "add", "put", "onto", "on", "over", "with"], of: surface)

        if material.needsFullSurface {
            // addGround only forwards friction; the rule carries the rest.
            operations.append(.setMaterial(target: .ground, material: material))
        }
        operations.append(.addGround(friction: material.friction))
    }

    // MARK: bodies

    private mutating func parseBodies() {
        guard let nounIndex = tokens.items.indices.first(where: { i in
            tokens.live(i) && Vocabulary.shapeNouns[tokens.items[i].text] != nil
        }), let kind = Vocabulary.shapeNouns[tokens.items[nounIndex].text] else { return }

        let strong = tokens.first(of: Vocabulary.strongAddVerbs)
        let weak = tokens.first(of: Vocabulary.weakAddVerbs)
        subject = kind

        // The sub-parsers below claim tokens as they go, so the stream is
        // snapshotted first: if this turns out not to be an add at all, the
        // words are handed back untouched for the later rules to use.
        let snapshot = tokens

        // Placement first: it eats "of radius 0.4" and "from 2 m" before those
        // numbers can be mistaken for a body size or a count.
        let placement = parsePlacementClause()
        let material = parseBodyMaterial()
        let density = parseDensity()
        let size = parseSize(near: nounIndex, kind: kind)
        let count = parseCount(before: nounIndex, noun: tokens.items[nounIndex].text)

        // "make the boxes bouncy" is a material change, not an add. Require a
        // strong verb, or a weak verb plus something concrete to add.
        let concrete = count != nil || size != nil || placement.kindGiven
        if strong == nil && !(weak != nil && concrete) && count == nil {
            tokens = snapshot
            return
        }

        tokens.consume(nounIndex)
        if let strong { tokens.consume(strong) }
        if let weak { tokens.consume(weak) }

        let shape = ShapeSpec(kind: kind, size: size ?? ShapeSpec.defaultSize(for: kind))
        let plural = Vocabulary.pluralShapeNouns.contains(tokens.items[nounIndex].text)
        let bodyCount = count ?? placement.impliedCount ?? (plural ? 3 : 1)
        let isDrop = strong.map { Vocabulary.dropVerbs.contains(tokens.items[$0].text) } ?? false
        let spec = placement.build(count: bodyCount, extent: shape.verticalExtent,
                                   seed: seed, dropping: isDrop)

        addedBodies = true
        operations.append(.addBodies(count: bodyCount, shape: shape, at: spec,
                                     material: material ?? .default,
                                     density: density ?? MaterialDefaults.density(material)))
    }

    /// Accumulated placement words, resolved once the count and body size are known.
    struct PlacementDraft {
        var height: Double?
        var ring: Bool = false
        var ringRadius: Double?
        var grid: Bool = false
        var gridColumns: Int?
        var gridSpacing: Double?
        var stack: Bool = false
        var stackSpacing: Double?
        var scatter: Bool = false
        var scatterSize: Double?
        var yaw: Double = 0
        /// "4 by 4" names a body count as well as a shape.
        var impliedCount: Int?

        var kindGiven: Bool { ring || grid || stack || scatter || height != nil }

        func build(count: Int, extent: Double, seed: UInt64, dropping: Bool) -> PlacementSpec {
            let rest = extent * 0.5 + 0.002
            if stack {
                // A stack needs almost no jitter or it topples on frame one.
                return PlacementSpec(arrangement: .stack(spacing: stackSpacing,
                                                         base: height ?? 0),
                                     jitter: 0.002, yaw: yaw, yawJitter: 0.02, seed: seed)
            }
            if ring {
                let radius = ringRadius ?? max(Double(count) * extent * 0.3, 0.3)
                return PlacementSpec(arrangement: .ring(radius: radius,
                                                        height: height ?? rest),
                                     jitter: 0.005, yaw: yaw, yawJitter: 0, seed: seed)
            }
            if grid {
                let columns = gridColumns
                    ?? max(Int(Double(count).squareRoot().rounded(.up)), 1)
                return PlacementSpec(arrangement: .grid(columns: columns,
                                                        spacing: gridSpacing,
                                                        height: height ?? rest),
                                     jitter: 0.004, yaw: yaw, yawJitter: 0.05, seed: seed)
            }
            if scatter {
                let side = scatterSize ?? max(Double(count).squareRoot() * extent * 2, 0.6)
                return PlacementSpec(arrangement: .scattered(size: Vector3(side, side,
                                                                          extent * 2),
                                                             height: height ?? (rest + extent)),
                                     jitter: 0.01, yaw: yaw, yawJitter: .pi, seed: seed)
            }
            let h = height ?? (dropping ? 1.0 : rest)
            // A body that is being dropped can spin freely; one that is being
            // placed keeps roughly the orientation the user asked for.
            return PlacementSpec(arrangement: .height(h), jitter: 0.02, yaw: yaw,
                                 yawJitter: dropping ? .pi : 0.15, seed: seed)
        }
    }

    private mutating func parsePlacementClause() -> PlacementDraft {
        var draft = PlacementDraft()

        // Height: "from 2 m", "at a height of 30 cm", "2 metres up".
        let heightTriggers: Set<String> = ["from", "at", "above", "height", "up", "high"]
        for trigger in tokens.all(of: heightTriggers) {
            guard let numberIndex = tokens.nearestNumber(to: trigger, maxDistance: 3),
                  tokens.hasLengthUnit(numberIndex) || tokens.isUnitless(numberIndex),
                  let value = tokens.metres(at: numberIndex), value >= 0 else { continue }
            draft.height = value
            tokens.consume(trigger, numberIndex)
            if let filler = tokens.first(of: ["height", "up", "high", "altitude"]) {
                tokens.consume(filler)
            }
            break
        }

        if let index = tokens.first(of: ["ring", "circle", "arc"]) {
            draft.ring = true
            tokens.consume(index)
            if let radiusWord = tokens.first(of: ["radius", "r", "diameter"]),
               let numberIndex = tokens.nearestNumber(to: radiusWord, maxDistance: 3),
               let value = tokens.metres(at: numberIndex) {
                draft.ringRadius = tokens.items[radiusWord].text == "diameter"
                    ? value * 0.5 : value
                tokens.consume(radiusWord, numberIndex)
            } else if let numberIndex = tokens.nearestNumber(to: index, maxDistance: 3,
                                                             direction: 1),
                      let value = tokens.metres(at: numberIndex) {
                draft.ringRadius = value
                tokens.consume(numberIndex)
            }
        }

        if let index = tokens.first(of: ["grid", "array", "lattice", "rows", "matrix"]) {
            draft.grid = true
            tokens.consume(index)
            // "4 by 4" or "4 x 4".
            if let by = tokens.first(of: ["by", "x"]),
               let left = tokens.nearestNumber(to: by, maxDistance: 2, direction: -1),
               let value = tokens.items[left].number {
                let columns = max(Int(value.rounded()), 1)
                draft.gridColumns = columns
                tokens.consume(by, left)
                if let right = tokens.nearestNumber(to: by, maxDistance: 2, direction: 1),
                   let rows = tokens.items[right].number, rows >= 1 {
                    // "4 by 4" states the count as well as the shape.
                    draft.impliedCount = columns * max(Int(rows.rounded()), 1)
                    tokens.consume(right)
                }
            } else if let numberIndex = tokens.nearestNumber(to: index, maxDistance: 3,
                                                             direction: 1),
                      tokens.isUnitless(numberIndex),
                      let value = tokens.items[numberIndex].number {
                draft.gridColumns = max(Int(value.rounded()), 1)
                tokens.consume(numberIndex)
            }
            if let spacingWord = tokens.first(of: ["spacing", "spaced", "pitch", "apart"]),
               let numberIndex = tokens.nearestNumber(to: spacingWord, maxDistance: 3),
               let value = tokens.metres(at: numberIndex) {
                draft.gridSpacing = value
                tokens.consume(spacingWord, numberIndex)
            }
        }

        if let index = tokens.first(of: ["stack", "stacked", "tower", "column"]) {
            draft.stack = true
            tokens.consume(index)
            if let gapWord = tokens.first(of: ["gap", "spacing", "spaced", "pitch"]),
               let numberIndex = tokens.nearestNumber(to: gapWord, maxDistance: 3),
               let value = tokens.metres(at: numberIndex) {
                draft.stackSpacing = value
                tokens.consume(gapWord, numberIndex)
            }
        }

        // "rotated 45 degrees" / "turned a quarter turn". The angle reader
        // converts degrees and treats a bare number as radians.
        if let word = tokens.first(of: ["rotated", "rotate", "tilted", "turned", "yaw",
                                        "angled", "spun"]),
           let numberIndex = tokens.nearestNumber(to: word, maxDistance: 3),
           let value = tokens.radians(at: numberIndex) {
            draft.yaw = value
            tokens.consume(word, numberIndex)
        }

        if let index = tokens.first(of: ["scattered", "scatter", "random", "randomly",
                                         "strewn", "spread", "pile", "heap", "around"]) {
            draft.scatter = true
            tokens.consume(index)
            if let overWord = tokens.first(of: ["over", "across", "within", "inside"]),
               let numberIndex = tokens.nearestNumber(to: overWord, maxDistance: 3),
               let value = tokens.metres(at: numberIndex) {
                draft.scatterSize = value
                tokens.consume(overWord, numberIndex)
            }
        }

        return draft
    }

    private mutating func parseBodyMaterial() -> MaterialSpec? {
        guard let index = tokens.items.indices.first(where: { i in
            tokens.live(i) && Vocabulary.materials[tokens.items[i].text] != nil
        }), let spec = Vocabulary.materials[tokens.items[index].text] else { return nil }
        tokens.consume(index)
        return spec
    }

    private mutating func parseDensity() -> Double? {
        if let word = tokens.first(of: ["density", "rho"]),
           let numberIndex = tokens.nearestNumber(to: word, maxDistance: 3),
           let value = tokens.items[numberIndex].number, value > 0 {
            tokens.consume(word, numberIndex)
            return value
        }
        if let index = tokens.items.indices.first(where: { i in
            tokens.live(i) && tokens.items[i].unit == .densitySI
        }), let value = tokens.items[index].number, value > 0 {
            tokens.consume(index)
            return value
        }
        if let index = tokens.items.indices.first(where: { i in
            tokens.live(i) && Vocabulary.densities[tokens.items[i].text] != nil
        }), let value = Vocabulary.densities[tokens.items[index].text] {
            tokens.consume(index)
            return value
        }
        return nil
    }

    private mutating func parseSize(near noun: Int, kind: ShapeSpec.Kind) -> Double? {
        // Only an explicit length unit counts as a body size; a bare number in
        // this position is far more likely to be a count.
        let candidates = tokens.numbers { $0.unit?.lengthInMetres != nil }
        guard !candidates.isEmpty else { return nil }
        let best = candidates.min { abs($0 - noun) < abs($1 - noun) }
        guard let index = best, let value = tokens.metres(at: index), value > 0 else { return nil }
        tokens.consume(index)
        if let wideWord = tokens.first(of: ["wide", "across", "tall", "sized", "size"]) {
            tokens.consume(wideWord)
        }
        return value
    }

    private mutating func parseCount(before noun: Int, noun word: String) -> Int? {
        if let index = tokens.nearestNumber(to: noun, maxDistance: 4, direction: -1,
                                            where: { $0.unit == nil }),
           let value = tokens.items[index].number, value >= 1, value <= 4096 {
            tokens.consume(index)
            return Int(value.rounded())
        }
        // "a box", "another sphere".
        if noun > 0, tokens.live(noun - 1),
           ["a", "an", "another", "one"].contains(tokens.items[noun - 1].text) {
            tokens.consume(noun - 1)
            return 1
        }
        return nil
    }

    // MARK: impulse

    private mutating func parseImpulse() {
        guard let verb = tokens.first(of: Vocabulary.impulseVerbs) else { return }
        tokens.consume(verb)

        var direction = Vector3(1, 0, 0)
        if let index = tokens.items.indices.first(where: { i in
            tokens.live(i) && Vocabulary.directions[tokens.items[i].text] != nil
        }), let value = Vocabulary.directions[tokens.items[index].text] {
            direction = value
            tokens.consume(index)
        }

        var magnitude = 5.0
        if let index = tokens.nearestNumber(to: verb, maxDistance: 6, direction: 0,
                                            where: { $0.unit == nil || $0.unit == .newtonSecond }),
           let value = tokens.items[index].number, value > 0 {
            magnitude = value
            tokens.consume(index)
        }
        if let word = tokens.first(of: ["with", "at", "force", "impulse", "hard"]) {
            tokens.consume(word)
        }

        let target: TargetSpec
        if let nounIndex = tokens.items.indices.first(where: { i in
            tokens.live(i) && Vocabulary.shapeNouns[tokens.items[i].text] != nil
        }), let kind = Vocabulary.shapeNouns[tokens.items[nounIndex].text] {
            tokens.consume(nounIndex)
            target = .shape(kind)
        } else if let kind = subject {
            target = .shape(kind)
        } else {
            if let word = tokens.first(of: ["everything", "all", "them", "bodies"]) {
                tokens.consume(word)
            }
            target = .all
        }
        operations.append(.applyImpulse(target: target,
                                        direction: [direction.x, direction.y, direction.z],
                                        magnitude: magnitude))
    }

    // MARK: standalone material

    private mutating func parseStandaloneMaterial() {
        guard !addedBodies else { return }
        guard let index = tokens.items.indices.first(where: { i in
            tokens.live(i) && Vocabulary.materials[tokens.items[i].text] != nil
        }), let spec = Vocabulary.materials[tokens.items[index].text] else { return }
        tokens.consume(index)

        var target = TargetSpec.all
        if let nounIndex = tokens.items.indices.first(where: { i in
            tokens.live(i) && Vocabulary.shapeNouns[tokens.items[i].text] != nil
        }), let kind = Vocabulary.shapeNouns[tokens.items[nounIndex].text] {
            target = .shape(kind)
            tokens.consume(nounIndex)
        } else if let kind = subject {
            target = .shape(kind)
        }
        if let verb = tokens.first(of: ["make", "set", "turn"]) { tokens.consume(verb) }
        operations.append(.setMaterial(target: target, material: spec))
    }

    // MARK: helpers

    /// Claims filler words sitting within two tokens of `origin`, so that
    /// "set gravity to the moon" does not report "set" as unmatched.
    private mutating func consumeNearby(_ words: Set<String>, of origin: Int) {
        for offset in [-3, -2, -1, 1, 2] {
            let index = origin + offset
            guard tokens.live(index), words.contains(tokens.items[index].text) else { continue }
            tokens.consume(index)
        }
    }

    // MARK: result

    /// Significant tokens: numerals and content words, ignoring articles,
    /// absorbed unit words and folded numeral tails.
    private func significantIndices() -> [Int] {
        tokens.items.indices.filter { index in
            let item = tokens.items[index]
            if item.absorbed || item.text.isEmpty { return false }
            if item.isNumber { return true }
            return !stopWords.contains(item.text)
        }
    }

    func result() -> ParsedIntent? {
        guard !operations.isEmpty else { return nil }
        let significant = significantIndices()
        let unclaimed = significant.filter { !tokens.items[$0].consumed }
        let matched = significant.count - unclaimed.count
        let ratio = significant.isEmpty ? 1.0 : Double(matched) / Double(significant.count)
        let confidence = unclaimed.isEmpty ? 1.0 : max(0.15, min(0.95, 0.45 + 0.55 * ratio))

        var seen = Set<String>()
        var unmatched: [String] = []
        for index in unclaimed where !seen.contains(tokens.items[index].text) {
            seen.insert(tokens.items[index].text)
            unmatched.append(tokens.items[index].text)
        }

        // Rules fire in grammar order, not execution order, so the operations
        // are sorted into a legal phase sequence and the summary is written
        // from that sequence rather than from the order the words appeared in.
        let sorted = ScenePlan(operations: operations).ordered.operations
        return ParsedIntent(plan: ScenePlan(operations: sorted), confidence: confidence,
                            unmatched: unmatched)
    }
}

/// Defaults that depend on the material a batch was given.
enum MaterialDefaults {
    static func density(_ material: MaterialSpec?) -> Double {
        guard let material else { return 500 }
        switch material.name {
        case "steel": return 7800
        case "ice": return 917
        case "rubber", "bouncy", "sticky": return 1200
        case "wood": return 600
        case "glass": return 2500
        default: return 500
        }
    }
}

extension ShapeSpec {
    /// Hand-sized defaults, matching the reference scenes.
    static func defaultSize(for kind: Kind) -> Double {
        switch kind {
        case .box: return 0.2
        case .sphere: return 0.18
        case .capsule: return 0.12
        case .cylinder: return 0.15
        }
    }
}

// MARK: - IntentParser

public enum IntentParser {

    /// Deterministic parse. Returns nil only when nothing actionable was found.
    /// Never throws and never traps: unknown words end up in `unmatched`.
    public static func parse(_ text: String) -> ParsedIntent? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 2000 else { return nil }
        var grammar = Grammar(text: trimmed)
        grammar.run()
        return grammar.result()
    }

    /// Command-palette completions, ranked: prefix matches first, then
    /// token-subset matches. Scene names come from `SceneLibrary` so the list
    /// cannot drift out of date.
    public static func suggestions(for partial: String) -> [String] {
        let normalized = partial.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        var pool = templates
        pool.append(contentsOf: SceneLibrary.all.map { "load the \($0.id)" })

        guard !normalized.isEmpty else { return Array(pool.prefix(8)) }

        let words = normalized.split(separator: " ").map(String.init)
        var scored: [(text: String, score: Int)] = []
        for candidate in pool {
            var score = 0
            if candidate.hasPrefix(normalized) {
                score = 100
            } else if candidate.contains(normalized) {
                score = 60
            } else {
                let hits = words.filter { candidate.contains($0) }.count
                guard hits > 0 else { continue }
                score = 10 * hits
                // A trailing partial word should still complete: "grav" -> gravity.
                if let last = words.last, last.count >= 3,
                   candidate.split(separator: " ").contains(where: { $0.hasPrefix(last) }) {
                    score += 25
                }
            }
            scored.append((candidate, score))
        }

        // Nothing looked familiar: offer the partial's own most likely finish.
        if scored.isEmpty {
            if let last = words.last, last.count >= 2 {
                let extended = pool.filter { $0.split(separator: " ")
                    .contains { $0.hasPrefix(last) } }
                if !extended.isEmpty { return Array(extended.prefix(8)) }
            }
            return Array(pool.prefix(6))
        }

        return scored
            .sorted { lhs, rhs in
                lhs.score == rhs.score
                    ? lhs.text.count < rhs.text.count
                    : lhs.score > rhs.score
            }
            .prefix(8)
            .map(\.text)
    }

    /// Full readback. The palette shows this before applying anything, so the
    /// user sees both what will happen and what was ignored.
    public static func explain(_ intent: ParsedIntent) -> String {
        var lines: [String] = []
        lines.append(intent.plan.summary)
        lines.append("")
        if intent.plan.operations.isEmpty {
            lines.append("No operations.")
        } else {
            for (index, step) in intent.plan.describedSteps.enumerated() {
                lines.append("  \(index + 1). \(step)")
            }
        }
        lines.append("")
        lines.append("Confidence: " + fixed(intent.confidence * 100, 0) + "%")

        if !intent.unmatched.isEmpty {
            lines.append("Ignored: " + intent.unmatched.joined(separator: ", "))
        }

        var notes: [String] = []
        let addsBodies = intent.plan.operations.contains {
            if case .addBodies = $0 { return true }
            return false
        }
        let addsGround = intent.plan.operations.contains {
            if case .addGround = $0 { return true }
            return false
        }
        if addsBodies && !addsGround {
            notes.append("this plan adds no ground, so new bodies fall until they hit "
                + "whatever is already in the scene")
        }
        if intent.plan.requiresRebuild {
            notes.append("changes topology, so the world is rebuilt and the current "
                + "simulation state is lost")
        }
        if intent.confidence < 0.6 {
            notes.append("low confidence -- check the steps above before applying")
        }
        if !notes.isEmpty {
            lines.append("Note: " + notes.joined(separator: "; ") + ".")
        }
        return lines.joined(separator: "\n")
    }

    /// Exemplars, doubling as the completion pool.
    static let templates: [String] = [
        "drop 5 boxes from 2 m",
        "drop five 10 cm boxes from 2 metres onto ice",
        "add ten 5 cm spheres in a ring of radius 0.4",
        "add 16 boxes in a grid spaced 0.3 m",
        "stack 8 boxes",
        "scatter 20 marbles over 2 m",
        "make the ground icy",
        "make the ground bouncy",
        "make the boxes sticky",
        "add a frictionless floor",
        "ground friction 0.3",
        "set gravity to the moon",
        "set gravity to mars",
        "gravity 0 0 -3.7",
        "gravity off",
        "timestep 1 ms",
        "run at 500 hz",
        "run for 3 seconds",
        "run 500 steps",
        "40 solver iterations",
        "use rk4",
        "use semi-implicit euler",
        "push the boxes right with 8 n s",
        "reset",
        "add a dozen wooden crates in a stack",
        "drop 3 heavy steel spheres from 1.5 m",
        "add 4 boxes rotated 45 degrees",
    ]
}

// MARK: - Backends

public enum IntentBackendError: Error, CustomStringConvertible {
    case emptyInput
    case notUnderstood(String)
    case malformedPlan(String)

    public var description: String {
        switch self {
        case .emptyInput:
            return "Nothing to parse."
        case .notUnderstood(let text):
            return "Could not turn \"\(text)\" into a scene plan."
        case .malformedPlan(let detail):
            return "The model returned something that is not a ScenePlan: \(detail)"
        }
    }
}

public protocol IntentBackend: Sendable {
    func parse(_ text: String) async throws -> ParsedIntent?
}

/// The default. Zero dependencies, zero network, fully reproducible.
public struct GrammarBackend: IntentBackend {
    public init() {}

    public func parse(_ text: String) async throws -> ParsedIntent? {
        IntentParser.parse(text)
    }
}

/// Opt-in fallback. Consulted only when the grammar is unsure, and its output
/// is decoded into the very same `ScenePlan` type -- the model can suggest a
/// plan, it can never reach the `World`.
public struct ModelBackend: IntentBackend {
    public typealias Completion = @Sendable (String) async throws -> String

    /// Below this grammar confidence, ask the model.
    public var minimumGrammarConfidence: Double
    private let complete: Completion

    public init(minimumGrammarConfidence: Double = 0.6,
                complete: @escaping Completion) {
        self.minimumGrammarConfidence = minimumGrammarConfidence
        self.complete = complete
    }

    public func parse(_ text: String) async throws -> ParsedIntent? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw IntentBackendError.emptyInput }

        let grammar = IntentParser.parse(trimmed)
        if let grammar, grammar.confidence >= minimumGrammarConfidence {
            return grammar
        }

        let raw = try await complete(ModelBackend.prompt(for: trimmed))
        guard let data = ModelBackend.extractJSON(raw) else {
            if let grammar { return grammar }
            throw IntentBackendError.malformedPlan("no JSON object in the response")
        }

        do {
            let plan = try ScenePlan.decode(json: data).ordered
            try plan.validate()
            guard !plan.isEmpty else {
                if let grammar { return grammar }
                throw IntentBackendError.notUnderstood(trimmed)
            }
            // Capped below 1: a model plan has not been mechanically verified
            // against the input the way a fully consumed grammar parse has.
            return ParsedIntent(plan: plan, confidence: 0.75,
                                unmatched: grammar?.unmatched ?? [])
        } catch {
            if let grammar { return grammar }
            throw IntentBackendError.malformedPlan(String(describing: error))
        }
    }

    /// Schema-carrying prompt. Kept beside the types it describes so the two
    /// cannot drift apart.
    public static func prompt(for text: String) -> String {
        """
        Convert the instruction into a Kinetic ScenePlan. Reply with JSON only.

        Schema:
        {"summary": String,
         "operations": [ one of
           {"addBodies": {"count": Int,
                          "shape": {"kind": "box|sphere|capsule|cylinder",
                                    "size": Double, "length": Double?},
                          "at": {"arrangement": {"height": {"_0": Double}}
                                              | {"grid": {"columns": Int, "spacing": Double?,
                                                          "height": Double}}
                                              | {"stack": {"spacing": Double?, "base": Double}}
                                              | {"ring": {"radius": Double, "height": Double}}
                                              | {"scattered": {"size": {"x":D,"y":D,"z":D},
                                                               "height": Double}},
                                 "center": {"x": D, "y": D, "z": D},
                                 "jitter": Double, "yawJitter": Double, "seed": UInt64},
                          "material": {"name": String, "friction": Double,
                                       "restitution": Double, "torsionalFriction": Double},
                          "density": Double}},
           {"addGround": {"friction": Double}},
           {"setGravity": {"_0": {"x": D, "y": D, "z": D}}},
           {"setTimestep": {"_0": Double}},
           {"setSolverIterations": {"_0": Int}},
           {"applyImpulse": {"target": {"all": {}},
                             "direction": [D, D, D], "magnitude": Double}},
           {"loadScene": {"_0": "stack|arm|quadruped|cartpole|chain|dominoes|mixed"}},
           {"run": {"seconds": Double}},
           {"reset": {}},
           {"setIntegrator": {"_0": "euler|rk4|implicit"}}
         ]}

        Rules: SI units throughout. Z is up, gravity is negative Z. Sizes are
        full extents in metres. Put every topology operation (addBodies,
        addGround, setMaterial, loadScene) before every state operation (run,
        reset, applyImpulse). Choose a fixed integer seed so the scene is
        reproducible.

        Instruction: \(text)
        """
    }

    /// Pulls the outermost JSON object out of a reply that may be fenced or
    /// wrapped in prose.
    static func extractJSON(_ raw: String) -> Data? {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"),
              start < end else { return nil }
        return String(raw[start...end]).data(using: .utf8)
    }
}
