#if os(macOS)
import Foundation

/// Tools an agent could be given for a page that declared none, worked out from its accessibility
/// tree, and whether the tree is good enough to work them out from ([accessibility.md]).
nonisolated struct DerivedPageTools: Sendable {
    nonisolated enum Verdict: Sendable, Equatable {
        case good
        /// No web area, or next to nothing in it: a canvas app, a PDF, a page still being built.
        case noTree
        /// Fewer controls and fields than make a page worth tools — an article, a landing page.
        case tooFew
        /// Enough of them, but too many without a name to say what they do.
        case unnamed
    }

    nonisolated struct Tool: Sendable, Identifiable {
        nonisolated enum Kind: Sendable { case form, press, type }

        /// The node the tool acts on: the form, the control or the field.
        let id: Int
        let kind: Kind
        let name: String
        /// For a form: the names of its fields, in document order.
        let inputs: [String]
    }

    static let minimumActionable = 3
    static let minimumNamedShare = 0.6

    let tools: [Tool]
    /// Controls and fields on the part of the page that was read; links are left out, since
    /// following one is navigation and an agent has that already.
    let actionable: Int
    let named: Int
    let verdict: Verdict

    init(_ nodes: [AXPageNode]) {
        let acting = nodes.filter { $0.id > 1 && Self.acts($0) }
        actionable = acting.count
        named = acting.filter { !$0.name.isEmpty }.count
        if nodes.count < 3 {
            verdict = .noTree
        } else if actionable < Self.minimumActionable {
            verdict = .tooFew
        } else if Double(named) < Double(actionable) * Self.minimumNamedShare {
            verdict = .unnamed
        } else {
            verdict = .good
        }
        tools = verdict == .good ? Self.derive(nodes, acting: acting) : []
    }

    private static func acts(_ node: AXPageNode) -> Bool {
        switch node.kind {
        case .field: true
        case .control: node.role != "AXLink"
        default: false
        }
    }

    /// A form or search region with fields in it is one tool; everything named outside one is a
    /// tool of its own.
    private static func derive(_ nodes: [AXPageNode], acting: [AXPageNode]) -> [Tool] {
        func form(of node: AXPageNode) -> AXPageNode? {
            var parent = node.parent
            while let id = parent {
                let ancestor = nodes[id - 1]
                if ["form", "search"].contains(ancestor.ariaRole) { return ancestor }
                parent = ancestor.parent
            }
            return nil
        }
        var members: [Int: [AXPageNode]] = [:]
        var loose: [AXPageNode] = []
        for node in acting {
            if let form = form(of: node) { members[form.id, default: []].append(node) } else { loose.append(node) }
        }
        var tools: [Tool] = []
        for (formID, inside) in members.sorted(by: { $0.key < $1.key }) {
            let fields = inside.filter { $0.kind == .field && !$0.name.isEmpty }
            guard !fields.isEmpty else {
                loose += inside
                continue
            }
            let region = nodes[formID - 1]
            let submit = inside.first { $0.kind == .control && !$0.name.isEmpty }
            let name = [region.name, submit?.name ?? "", fields[0].name].first { !$0.isEmpty } ?? ""
            tools.append(Tool(id: formID, kind: .form, name: name, inputs: fields.map(\.name)))
        }
        for node in loose where !node.name.isEmpty {
            tools.append(Tool(id: node.id, kind: node.kind == .field ? .type : .press, name: node.name, inputs: []))
        }
        return tools.sorted { $0.id < $1.id }
    }
}
#endif
