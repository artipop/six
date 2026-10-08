import Foundation

/// What a tool call is called in the panel.
///
/// An agent namespaces the tools it got from an MCP server by mangling them into
/// `mcp__<server>__<tool>` — the wire's way of keeping two servers' `search` apart, not a name meant
/// to be read. Savoia shows the two parts it is made of, the server and the method, with a space
/// between them: `mcp__savoia__open_window` reads `Savoia open_window`.
///
/// Titles that aren't mangled (an agent's own `Read`, `Bash`, a title it wrote itself) are left
/// exactly as they came.
nonisolated enum AgentToolName {
    static let mcpPrefix = "mcp__"

    /// The tool's own name when `raw` is exactly a tool of `server` as an agent mangles it.
    static func tool(_ raw: String, of server: String) -> String? {
        let prefix = mcpPrefix + server + "__"
        return raw.hasPrefix(prefix) && raw.count > prefix.count ? String(raw.dropFirst(prefix.count)) : nil
    }

    static func display(_ raw: String) -> String {
        guard raw.contains(mcpPrefix) else { return raw }
        // Word by word: a title may be the bare name, or the name inside a sentence the agent wrote.
        return raw.split(separator: " ", omittingEmptySubsequences: false)
            .map { word -> String in
                guard let start = word.range(of: mcpPrefix)?.lowerBound else { return String(word) }
                let head = word[word.startIndex..<start]
                let mangled = word[word.index(start, offsetBy: mcpPrefix.count)...]
                return head + mangled.replacingOccurrences(of: "__", with: " ")
            }
            .joined(separator: " ")
    }
}
