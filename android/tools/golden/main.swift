import Foundation

@MainActor func emit() {
    let viewports: [(String, CGSize)] = [
        ("mac", CGSize(width: 1600, height: 1000)),
        ("retina", CGSize(width: 3200, height: 2000)),
        ("tiny", CGSize(width: 300, height: 300)),
        ("narrow", CGSize(width: 320, height: 240)),
        ("phone-portrait", CGSize(width: 1179, height: 2556)),
        ("phone-landscape", CGSize(width: 2556, height: 1179)),
        ("tablet", CGSize(width: 1024, height: 1366)),
    ]
    var out: [String] = []
    for (name, size) in viewports {
        let l = NiriLayout()
        l.updateViewport(size)
        var ws = NiriWorkspace()
        ws.columns = (0..<4).map { _ in NiriColumn(tabID: UUID()) }
        let frames = l.columnFrames(ws).map {
            String(format: "%.6f,%.6f,%.6f,%.6f", $0.origin.x, $0.origin.y, $0.width, $0.height)
        }
        out.append("""
        {"name":"\(name)","viewport":[\(size.width),\(size.height)],\
        "gap":\(String(format: "%.6f", l.gap)),\
        "columnHeight":\(String(format: "%.6f", l.columnHeight)),\
        "columnWidth":\(String(format: "%.6f", l.columnWidth)),\
        "frames":["\(frames.joined(separator: "\",\""))"],\
        "contentWidth":\(String(format: "%.6f", l.contentWidth(ws)))}
        """)
    }
    print("[\n" + out.joined(separator: ",\n") + "\n]")
}

MainActor.assumeIsolated { emit() }
