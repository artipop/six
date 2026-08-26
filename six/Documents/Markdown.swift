import Foundation

/// A small Markdown → HTML renderer for the document preview and the HTML/PDF export. Covers what a
/// research document is made of — headings, paragraphs, lists, quotes, fenced code, tables, rules,
/// links, images, emphasis, inline code, reference-style citations — and nothing exotic. Rendering in
/// Swift rather than in the page keeps the preview free of a bundled JavaScript library.
nonisolated enum Markdown {
    // MARK: Blocks

    static func html(from markdown: String) -> String {
        let references = referenceLinks(in: markdown)
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var out: [String] = []
        var i = 0
        var paragraph: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            out.append("<p>\(inline(paragraph.joined(separator: "\n"), references: references))</p>")
            paragraph.removeAll()
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty { flushParagraph(); i += 1; continue }

            // Fenced code
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) { code.append(lines[i]); i += 1 }
                i += 1
                let cls = language.isEmpty ? "" : " class=\"language-\(escape(language))\""
                out.append("<pre><code\(cls)>\(escape(code.joined(separator: "\n")))</code></pre>")
                continue
            }

            // Heading
            if let (level, text) = heading(trimmed) {
                flushParagraph()
                out.append("<h\(level) id=\"\(slug(text))\">\(inline(text, references: references))</h\(level)>")
                i += 1
                continue
            }

            // Rule
            if trimmed.count >= 3, trimmed.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" || $0 == " " }),
               Set(trimmed.filter { $0 != " " }).count == 1 {
                flushParagraph()
                out.append("<hr>")
                i += 1
                continue
            }

            // Reference definition — rendered as a numbered source line
            if let reference = referenceDefinition(trimmed) {
                flushParagraph()
                var html = "<div class=\"source\" id=\"source-\(reference.label)\"><span class=\"n\">[\(escape(reference.label))]</span> "
                html += "<a href=\"\(escape(reference.url))\">\(escape(reference.title.isEmpty ? reference.url : reference.title))</a>"
                if !reference.note.isEmpty { html += " <span class=\"note\">\(inline(reference.note, references: references))</span>" }
                i += 1
                // A following indented quote is the passage
                if i < lines.count, lines[i].hasPrefix("    > ") {
                    html += "<blockquote>\(escape(String(lines[i].dropFirst(6))))</blockquote>"
                    i += 1
                }
                out.append(html + "</div>")
                continue
            }

            // Blockquote
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quoted.append(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst().drop { $0 == " " }))
                    i += 1
                }
                out.append("<blockquote>\(html(from: quoted.joined(separator: "\n")))</blockquote>")
                continue
            }

            // Table
            if trimmed.hasPrefix("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flushParagraph()
                let header = cells(trimmed)
                let aligns = cells(lines[i + 1]).map(alignment)
                i += 2
                var rows: [[String]] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") { rows.append(cells(lines[i])); i += 1 }
                var table = "<table><thead><tr>"
                for (c, cell) in header.enumerated() { table += "<th\(alignAttribute(aligns, c))>\(inline(cell, references: references))</th>" }
                table += "</tr></thead><tbody>"
                for row in rows {
                    table += "<tr>"
                    for (c, cell) in row.enumerated() { table += "<td\(alignAttribute(aligns, c))>\(inline(cell, references: references))</td>" }
                    table += "</tr>"
                }
                out.append(table + "</tbody></table>")
                continue
            }

            // Lists
            if listItem(line) != nil {
                flushParagraph()
                out.append(list(lines, &i, references: references))
                continue
            }

            paragraph.append(trimmed)
            i += 1
        }
        flushParagraph()
        return out.joined(separator: "\n")
    }

    private static func heading(_ line: String) -> (Int, String)? {
        var level = 0
        var cursor = line.startIndex
        while cursor < line.endIndex, line[cursor] == "#", level < 6 { level += 1; cursor = line.index(after: cursor) }
        guard level > 0, cursor < line.endIndex, line[cursor] == " " else { return nil }
        let text = line[cursor...].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\s+#+$", with: "", options: .regularExpression)
        return text.isEmpty ? nil : (level, text)
    }

    /// `- item`, `* item`, `1. item`, with its indentation and whether it is ordered.
    private static func listItem(_ line: String) -> (indent: Int, ordered: Bool, text: String, checkbox: Bool?)? {
        let indent = line.prefix { $0 == " " }.count
        let rest = line.dropFirst(indent)
        var text: Substring
        var ordered = false
        if rest.hasPrefix("- ") || rest.hasPrefix("* ") || rest.hasPrefix("+ ") {
            text = rest.dropFirst(2)
        } else if let dot = rest.firstIndex(of: "."), rest[..<dot].allSatisfy(\.isNumber), !rest[..<dot].isEmpty,
                  rest.index(after: dot) < rest.endIndex, rest[rest.index(after: dot)] == " " {
            text = rest[rest.index(dot, offsetBy: 2)...]
            ordered = true
        } else {
            return nil
        }
        var checkbox: Bool?
        if text.hasPrefix("[ ] ") { checkbox = false; text = text.dropFirst(4) }
        else if text.hasPrefix("[x] ") || text.hasPrefix("[X] ") { checkbox = true; text = text.dropFirst(4) }
        return (indent, ordered, String(text), checkbox)
    }

    private static func list(_ lines: [String], _ i: inout Int, references: [String: (String, String)]) -> String {
        guard let first = listItem(lines[i]) else { return "" }
        let base = first.indent
        let tag = first.ordered ? "ol" : "ul"
        var html = "<\(tag)>"
        while i < lines.count {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                // A blank line ends the list unless the next non-blank line is still part of it.
                var j = i + 1
                while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
                if j < lines.count, let next = listItem(lines[j]), next.indent >= base { i = j; continue }
                break
            }
            guard let item = listItem(line), item.indent >= base else {
                // Continuation line of the previous item
                if line.prefix(base + 2).allSatisfy({ $0 == " " }), html.hasSuffix("</li>") {
                    html.removeLast(5)
                    html += " " + inline(line.trimmingCharacters(in: .whitespaces), references: references) + "</li>"
                    i += 1
                    continue
                }
                break
            }
            if item.indent > base {
                if html.hasSuffix("</li>") { html.removeLast(5) }
                html += list(lines, &i, references: references) + "</li>"
                continue
            }
            var body = inline(item.text, references: references)
            if let checkbox = item.checkbox {
                body = "<input type=\"checkbox\" disabled\(checkbox ? " checked" : "")> " + body
            }
            html += "<li>\(body)</li>"
            i += 1
        }
        return html + "</\(tag)>"
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|"), trimmed.contains("-") else { return false }
        return trimmed.allSatisfy { "|-: ".contains($0) }
    }

    private static func cells(_ line: String) -> [String] {
        var inner = line.trimmingCharacters(in: .whitespaces)
        if inner.hasPrefix("|") { inner.removeFirst() }
        if inner.hasSuffix("|") { inner.removeLast() }
        return inner.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func alignment(_ cell: String) -> String {
        switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
        case (true, true): "center"
        case (false, true): "right"
        default: ""
        }
    }

    private static func alignAttribute(_ aligns: [String], _ column: Int) -> String {
        guard aligns.indices.contains(column), !aligns[column].isEmpty else { return "" }
        return " style=\"text-align:\(aligns[column])\""
    }

    // MARK: References

    /// `[label]: url "title"` — reference-style links and the citations `cite` writes.
    private static func referenceDefinition(_ line: String) -> (label: String, url: String, title: String, note: String)? {
        let pattern = #"^\[([^\]]+)\]:\s+(\S+)(?:\s+"([^"]*)")?(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) else { return nil }
        let ns = line as NSString
        let title = match.range(at: 3).location == NSNotFound ? "" : ns.substring(with: match.range(at: 3))
        let note = ns.substring(with: match.range(at: 4)).trimmingCharacters(in: .whitespaces)
        return (ns.substring(with: match.range(at: 1)), ns.substring(with: match.range(at: 2)), title, note.hasPrefix("—") ? String(note.dropFirst()).trimmingCharacters(in: .whitespaces) : note)
    }

    private static func referenceLinks(in markdown: String) -> [String: (String, String)] {
        var map: [String: (String, String)] = [:]
        for line in markdown.split(separator: "\n") {
            if let reference = referenceDefinition(line.trimmingCharacters(in: .whitespaces)) {
                map[reference.label.lowercased()] = (reference.url, reference.title)
            }
        }
        return map
    }

    // MARK: Inline

    static func inline(_ text: String, references: [String: (String, String)] = [:]) -> String {
        // Protect code spans first, then escape, then the rest.
        var pieces: [String] = []
        var rest = Substring(text)
        while let tick = rest.firstIndex(of: "`") {
            let before = rest[..<tick]
            let afterTick = rest[rest.index(after: tick)...]
            guard let close = afterTick.firstIndex(of: "`") else { break }
            pieces.append(spans(String(before), references: references))
            pieces.append("<code>\(escape(String(afterTick[..<close])))</code>")
            rest = afterTick[afterTick.index(after: close)...]
        }
        pieces.append(spans(String(rest), references: references))
        return pieces.joined()
    }

    private static func spans(_ raw: String, references: [String: (String, String)]) -> String {
        var s = escape(raw)
        // Images ![alt](src)
        s = replace(s, #"!\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)"#) { m in "<img alt=\"\(m[1])\" src=\"\(m[2])\">" }
        // Links [text](url)
        s = replace(s, #"\[([^\]]+)\]\(([^)\s]+)(?:\s+"[^"]*")?\)"#) { m in "<a href=\"\(m[2])\">\(m[1])</a>" }
        // Reference links [text][label] and citations [n]
        s = replace(s, #"\[([^\]]+)\]\[([^\]]*)\]"#) { m in
            let label = (m[2].isEmpty ? m[1] : m[2]).lowercased()
            guard let target = references[label] else { return "[\(m[1])][\(m[2])]" }
            return "<a href=\"\(target.0)\" title=\"\(target.1)\">\(m[1])</a>"
        }
        s = replace(s, #"\[(\d+)\](?!\(|\[|:)"#) { m in
            guard references[m[1]] != nil else { return "[\(m[1])]" }
            return "<sup class=\"cite\"><a href=\"#source-\(m[1])\">[\(m[1])]</a></sup>"
        }
        // Bare URLs
        s = replace(s, #"(?<![\"'>=\w])(https?://[^\s<]+[^\s<.,;:!?)\]])"#) { m in "<a href=\"\(m[1])\">\(m[1])</a>" }
        // Emphasis
        s = replace(s, #"\*\*(.+?)\*\*"#) { m in "<strong>\(m[1])</strong>" }
        s = replace(s, #"__(.+?)__"#) { m in "<strong>\(m[1])</strong>" }
        s = replace(s, #"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])"#) { m in "<em>\(m[1])</em>" }
        s = replace(s, #"(?<![\w_])_(?!\s)(.+?)(?<!\s)_(?![\w_])"#) { m in "<em>\(m[1])</em>" }
        s = replace(s, #"~~(.+?)~~"#) { m in "<del>\(m[1])</del>" }
        // Hard line breaks inside a paragraph
        s = s.replacingOccurrences(of: "  \n", with: "<br>\n")
        return s
    }

    private static func replace(_ s: String, _ pattern: String, _ body: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return s }
        let ns = s as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            var groups: [String] = []
            for g in 0..<match.numberOfRanges {
                let r = match.range(at: g)
                groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
            }
            result += body(groups)
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func slug(_ text: String) -> String {
        let lowered = text.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        let kept = lowered.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        return kept.replacingOccurrences(of: "-+", with: "-", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    // MARK: Page

    /// A whole page: the rendered body inside a small stylesheet that follows the system appearance.
    static func page(title: String, markdown: String) -> String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light dark">
        <title>\(escape(title))</title>
        <style>
        :root { color-scheme: light dark; --fg: #1d1d1f; --bg: #ffffff; --muted: #6e6e73; --rule: #e5e5ea; --code: #f5f5f7; --link: #0a66c2; }
        @media (prefers-color-scheme: dark) { :root { --fg: #f5f5f7; --bg: #1c1c1e; --muted: #98989d; --rule: #3a3a3c; --code: #2c2c2e; --link: #6cb4ff; } }
        html { background: var(--bg); }
        body { margin: 0 auto; padding: 32px 40px 64px; max-width: 46rem; color: var(--fg); background: var(--bg);
               font: 16px/1.6 -apple-system, "SF Pro Text", "Helvetica Neue", sans-serif; -webkit-font-smoothing: antialiased; }
        h1 { font-size: 1.9em; line-height: 1.2; margin: 0 0 .6em; letter-spacing: -.01em; }
        h2 { font-size: 1.35em; margin: 1.6em 0 .5em; padding-bottom: .2em; border-bottom: 1px solid var(--rule); }
        h3 { font-size: 1.1em; margin: 1.3em 0 .4em; }
        p, ul, ol, blockquote, table, pre { margin: 0 0 1em; }
        a { color: var(--link); text-decoration: none; } a:hover { text-decoration: underline; }
        code { font: .9em ui-monospace, "SF Mono", Menlo, monospace; background: var(--code); padding: .1em .35em; border-radius: 4px; }
        pre { background: var(--code); padding: 12px 14px; border-radius: 8px; overflow-x: auto; } pre code { background: none; padding: 0; }
        blockquote { margin-left: 0; padding: .2em 1em; border-left: 3px solid var(--rule); color: var(--muted); }
        table { border-collapse: collapse; width: 100%; font-size: .95em; }
        th, td { text-align: left; padding: 6px 10px; border-bottom: 1px solid var(--rule); vertical-align: top; }
        th { font-weight: 600; }
        img { max-width: 100%; height: auto; border-radius: 6px; }
        hr { border: 0; border-top: 1px solid var(--rule); margin: 2em 0; }
        sup.cite { font-size: .75em; line-height: 0; } sup.cite a { padding: 0 .1em; }
        div.source { font-size: .92em; margin: 0 0 .6em; padding-left: 2.2em; text-indent: -2.2em; }
        div.source .n { color: var(--muted); display: inline-block; width: 2.2em; text-indent: 0; }
        div.source .note { color: var(--muted); }
        div.source blockquote { margin: .3em 0 0; text-indent: 0; font-size: .95em; }
        input[type=checkbox] { vertical-align: middle; margin-right: .4em; }
        </style></head>
        <body>
        \(html(from: markdown))
        </body></html>
        """
    }
}
