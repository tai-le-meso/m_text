import Foundation

/// One recorded action (T94).
///
/// `args` reuses `SettingValue` rather than defining a parallel JSON value type — macros and
/// settings have the same problem (typed values out of untyped JSON, bools distinguishable
/// from 0/1), and that code is already written and tested.
public struct MacroStep: Equatable {
    public let command: String
    public let args: [String: SettingValue]

    public init(command: String, args: [String: SettingValue] = [:]) {
        self.command = command
        self.args = args
    }

    /// Text a `"insert"` step types.
    public var insertedCharacters: String? {
        guard command == MacroStep.insertCommand else { return nil }
        return args["characters"]?.stringValue
    }

    /// Sublime's name for typing text, and the one command this app records specially —
    /// everything else is recorded as the selector it dispatched.
    public static let insertCommand = "insert"

    public static func insert(_ characters: String) -> MacroStep {
        MacroStep(command: insertCommand, args: ["characters": .string(characters)])
    }
}

public struct Macro: Equatable {
    public var steps: [MacroStep]

    public init(steps: [MacroStep] = []) {
        self.steps = steps
    }

    public var isEmpty: Bool { steps.isEmpty }
}

/// Reads and writes `.sublime-macro` files: a JSON array of `{"command":…, "args":{…}}`.
///
/// Deliberately tolerant in both directions. A step with an unusable shape is skipped rather
/// than failing the file, matching how grammars, settings and snippets all behave here — a
/// macro recorded by a newer build, or by real Sublime, should replay whatever it has in
/// common rather than nothing at all.
public enum MacroParser {

    public enum ParseError: Error, Equatable { case notAnArray }

    public static func parse(data: Data) throws -> Macro {
        // Same `//`-comment tolerance the other JSON-ish formats get; hand-edited macros
        // pick up comments the same way keymaps do.
        guard let text = String(data: data, encoding: .utf8) else { throw ParseError.notAnArray }
        let stripped = Data(KeymapParser.stripLineComments(text).utf8)
        let json = try JSONSerialization.jsonObject(with: stripped)
        guard let array = json as? [[String: Any]] else { throw ParseError.notAnArray }

        var steps: [MacroStep] = []
        for object in array {
            guard let command = object["command"] as? String, !command.isEmpty else { continue }
            var args: [String: SettingValue] = [:]
            if let raw = object["args"] as? [String: Any] {
                for (key, value) in raw {
                    if let converted = SettingValue(json: value) { args[key] = converted }
                }
            }
            steps.append(MacroStep(command: command, args: args))
        }
        return Macro(steps: steps)
    }

    public static func serialize(_ macro: Macro) throws -> Data {
        let array: [[String: Any]] = macro.steps.map { step in
            var object: [String: Any] = ["command": step.command]
            if !step.args.isEmpty {
                var args: [String: Any] = [:]
                for (key, value) in step.args { args[key] = value.jsonValue }
                object["args"] = args
            }
            return object
        }
        return try JSONSerialization.data(withJSONObject: array,
                                          options: [.prettyPrinted, .sortedKeys])
    }
}

public extension SettingValue {
    /// Back to a JSON-encodable value, for writing macros out.
    var jsonValue: Any {
        switch self {
        case .bool(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .string(let value): return value
        case .intArray(let value): return value
        case .stringArray(let value): return value
        }
    }
}

/// Accumulates steps while recording.
///
/// The one piece of real logic is **coalescing consecutive inserts**: typing "hello" arrives
/// as five separate `insertText` calls, and recording five steps would make the macro file
/// unreadable and replay five times slower for no benefit. Sublime coalesces the same way.
/// Anything that isn't an insert breaks the run, so "type `foo`, press Home, type `bar`"
/// stays three steps rather than collapsing into one.
public final class MacroRecorder {

    public private(set) var isRecording = false
    public private(set) var steps: [MacroStep] = []

    public init() {}

    public func start() {
        steps = []
        isRecording = true
    }

    /// Ends recording and returns what was captured, or nil if nothing was.
    @discardableResult
    public func stop() -> Macro? {
        isRecording = false
        guard !steps.isEmpty else { return nil }
        return Macro(steps: steps)
    }

    public func cancel() {
        isRecording = false
        steps = []
    }

    public func record(_ step: MacroStep) {
        guard isRecording else { return }
        if let characters = step.insertedCharacters,
           let last = steps.last, let previous = last.insertedCharacters {
            steps[steps.count - 1] = .insert(previous + characters)
            return
        }
        steps.append(step)
    }

    public func recordInsert(_ characters: String) {
        record(.insert(characters))
    }

    public func recordCommand(_ name: String, args: [String: SettingValue] = [:]) {
        record(MacroStep(command: name, args: args))
    }
}
