#if os(macOS)
import Foundation

/// Whether six is offered in other apps' Share menu — read and written where macOS keeps it.
///
/// A share extension ships inside the app but is switched on **outside** it: macOS registers a newly
/// installed one *disabled*, and the only switch is in System Settings, several screens deep, under a
/// list where six's entry is one line among a dozen. There is no `Info.plist` key that asks for it to
/// be on, and no framework call for it either — `pluginkit` is the whole interface, and it is the same
/// one System Settings drives.
///
/// So six does two things with it, and no more. It switches itself on **once**, at the first launch
/// that finds it off, because an extension nobody can find is a feature that does not exist; and it
/// puts the same switch in Configuration, so turning it off is one click rather than a search through
/// System Settings. Once is the whole of the promise: the record of having done it
/// (`ConfigurationStore.hasOfferedShareExtension`) is written whether or not it worked, so a person
/// who switches it back off is never overruled by the next launch.
///
/// Running a command-line tool for this is not elegant. It is what there is, it is what the setting's
/// own UI does, and six is not sandboxed — `docs/sharing.md`.
nonisolated enum ShareExtensionSwitch {
    /// The extension's identifier is the app's plus `.share`, in every configuration — so a
    /// development build asks about *its* extension and never about the installed one's.
    static var identifier: String { (Bundle.main.bundleIdentifier ?? "org.deffun.six") + ".share" }

    enum State: Sendable, Equatable {
        /// macOS has no record of it: the app was moved, or this build has not been registered yet.
        case unregistered
        case on
        case off
    }

    private static let tool = "/usr/bin/pluginkit"

    static func state() async -> State {
        // `pluginkit -m -i <id>` prints one line per matching plug-in, and the first character is the
        // switch: `+` for on, a space for off. No line at all means macOS has never seen it.
        guard let output = await run(["-m", "-i", identifier]) else { return .unregistered }
        guard let line = output.split(separator: "\n").first(where: { $0.contains(identifier) }) else { return .unregistered }
        return line.hasPrefix("+") ? .on : .off
    }

    @discardableResult
    static func set(_ on: Bool) async -> State {
        _ = await run(["-e", on ? "use" : "ignore", "-i", identifier])
        return await state()
    }

    /// The first launch that finds it off switches it on. Answers what it did, for the log.
    static func enableIfOff() async -> State {
        let before = await state()
        guard before == .off else { return before }
        return await set(true)
    }

    private static func run(_ arguments: [String]) async -> String? {
        await Task.detached(priority: .utility) { () -> String? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                Log.error(.app, "pluginkit \(arguments.joined(separator: " ")): \(error.localizedDescription)")
                return nil
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8)
        }.value
    }
}
#endif
