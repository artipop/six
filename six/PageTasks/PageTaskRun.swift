import Foundation

/// One step of a page task, and who decided it.
///
/// The record exists because of the question a hybrid raises the moment it works: *who pressed
/// that?* A cheap classifier answering in 20 ms and a language model answering in 4 s are both
/// "the agent" from the outside, and when a task goes wrong the only useful first question is which
/// of the two chose the step, how sure it was, and whether the choice was escalated. So every step
/// carries its decider, its probability and its latency, and the trace is what the person is shown
/// while the task runs — not a spinner.
nonisolated struct PageTaskStep: Identifiable, Sendable {
    let id = UUID()
    var number: Int
    var operation: String
    /// The element's ref in the snapshot the decision was made from, and how it read there.
    var ref: String?
    var target: String?
    var text: String?
    /// `system-one` names the endpoint's own model id (`jev-1.13.0`, `laya-browser`); `system-two`
    /// names the assistant's model. Both are what actually answered, not what was configured.
    var decider: String
    var probability: Double?
    var latencyMs: Int
    /// The step was handed to System 2 because System 1 was not sure enough.
    var escalated = false
    /// What System 1 wanted, when it was overruled — the only way to tell, afterwards, whether
    /// escalating was worth its seconds or whether the cheap decider had it right all along.
    var overruled: String?
    var outcome: String?
    var failed = false
    /// The page looked the same after the step as before it — set by the loop from the next
    /// snapshot, and the reason a decider stops being trusted for the step after.
    var changedNothing = false

    /// The line the person reads: `3. [laya-browser 0.93, 21 ms] CLICK e12 "Search"`.
    var line: String {
        var text = "\(number). [\(decider)"
        if let probability { text += String(format: " %.2f", probability) }
        text += ", \(latencyMs) ms\(escalated ? ", escalated" : "")] \(operation)"
        if let ref { text += " \(ref)" }
        if let target { text += " \"\(target)\"" }
        if let value = self.text, !value.isEmpty { text += " ← \"\(value)\"" }
        if let overruled { text += " (over \(overruled))" }
        if let outcome, !outcome.isEmpty { text += " — \(outcome)" }
        return text
    }
}

/// How a run ended, in the words the person is shown.
nonisolated enum PageTaskEnding: Sendable, Equatable {
    case done(String)
    case blocked(String)
    case stopped(String)

    var text: String {
        switch self {
        case .done(let why), .blocked(let why), .stopped(let why): why
        }
    }
}

nonisolated struct PageTaskRun: Sendable {
    var goal: String
    var windowID: UUID
    var steps: [PageTaskStep] = []
    var ending: PageTaskEnding?
    var startedAt = Date()

    /// What each decider spent: the point of the hybrid is that these two rows differ by two orders
    /// of magnitude, so the report says it in numbers rather than in adjectives.
    var summary: String {
        var byDecider: [String: (count: Int, ms: Int)] = [:]
        let agreed = steps.filter { $0.escalated && $0.overruled == nil }.count
        let overruled = steps.filter { $0.overruled != nil }.count
        for step in steps {
            var entry = byDecider[step.decider] ?? (0, 0)
            entry.count += 1
            entry.ms += step.latencyMs
            byDecider[step.decider] = entry
        }
        let parts = byDecider.sorted { $0.value.count > $1.value.count }.map { name, entry in
            "\(name): \(entry.count) × \(entry.ms / max(1, entry.count)) ms"
        }
        let seconds = String(format: "%.1f", Date().timeIntervalSince(startedAt))
        var text = "\(steps.count) steps in \(seconds) s — " + parts.joined(separator: ", ")
        let escalated = steps.filter(\.escalated).count
        if escalated > 0 { text += "; escalated \(escalated), of which the fast decider was overruled \(overruled) and confirmed \(agreed)" }
        return text
    }
}
