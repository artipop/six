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
        /// What a form's input takes: text, one of a list's options, or on and off.
        nonisolated enum Input: Sendable { case text, choice, toggle }

        /// The node the tool acts on: the form, the control or the field.
        let id: Int
        let kind: Kind
        let name: String
        /// For a form: the names of its fields, in document order.
        let inputs: [String]
        /// For a form: the nodes of those fields, parallel to `inputs`.
        var fields: [Int] = []
        /// For a form: what each field takes, parallel to `inputs`.
        var kinds: [Input] = []
        /// For a form: its last named button, which is what sends it.
        var submit: Int?
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
            // Radios are left out: each is named for its option ("Email"), not for the question.
            var fields: [(node: AXPageNode, input: Tool.Input)] = []
            for node in inside where !node.name.isEmpty && !fields.contains(where: { $0.node.name == node.name }) {
                if node.kind == .field { fields.append((node, .text)) }
                else if node.role == "AXPopUpButton" { fields.append((node, .choice)) }
                else if node.role == "AXCheckBox" { fields.append((node, .toggle)) }
            }
            guard fields.contains(where: { $0.input == .text }) else {
                loose += inside
                continue
            }
            let region = nodes[formID - 1]
            let submit = inside.last { $0.role == "AXButton" && !$0.name.isEmpty }
            // A form with no label of its own is named by WebKit from everything in it.
            let own = region.name.hasPrefix(fields[0].node.name) || region.name.count > 60 ? "" : region.name
            let name = [own, submit?.name ?? "", fields[0].node.name].first { !$0.isEmpty } ?? ""
            tools.append(Tool(id: formID, kind: .form, name: name, inputs: fields.map(\.node.name), fields: fields.map(\.node.id),
                              kinds: fields.map(\.input), submit: submit?.id))
        }
        for node in loose where !node.name.isEmpty {
            tools.append(Tool(id: node.id, kind: node.kind == .field ? .type : .press, name: node.name, inputs: []))
        }
        return tools.sorted { $0.id < $1.id }
    }
}
#endif
