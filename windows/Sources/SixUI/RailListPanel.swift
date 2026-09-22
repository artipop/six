import CRailInterop
import Foundation
import WinSDK

/// A list in a window of its own: History and Site Permissions — the Mac's two sheets and the Linux
/// front's two adwaita dialogs, over the same rows.
///
/// Plain Win32, like everything else here: an owned popup window with an `EDIT` to search in and an
/// owner-drawn `LISTBOX`, painted in the bar's colours. Owned rather than child, so it has a frame
/// of its own and can be moved off the page it is about; owner-drawn because a list box's own rows
/// are one line of system text, and a visit is two things — what it was and where.
///
/// Its keys are its own: `Enter` takes the selected row, `↑`/`↓` move through the list from the
/// search field, `Delete` forgets a row where that means something, `Esc` closes. They are taken out
/// of the queue by `route`, the same way the rail's are, because an `EDIT` and a `LISTBOX` each have
/// their own idea of what those keys do.
@MainActor
final class RailListPanel {
    struct Row {
        /// What the row stands for — the address for a visit, the site for a permission.
        let id: String
        let title: String
        let detail: String
    }

    private(set) var hwnd: HWND?
    private var searchHwnd: HWND?
    private var listHwnd: HWND?
    private var rows: [Row] = []

    private let title: String
    private let searchable: Bool
    private let emptyText: String
    private let hint: String
    private let source: (String) -> [Row]
    private let activate: ((Row) -> Void)?
    private let remove: ((Row) -> Void)?
    /// Told once the window is gone, so the owner can let go of it.
    var onClose: (() -> Void)?

    private var scale: Double = 1
    private var uiFont: HFONT?
    private var strongFont: HFONT?
    private var smallFont: HFONT?
    private var backgroundBrush: HBRUSH?
    private var fieldBrush: HBRUSH?

    private static let className = "SixListPanel"
    private static var registered = false

    init(title: String, searchable: Bool, emptyText: String, hint: String,
         rows: @escaping (String) -> [Row],
         activate: ((Row) -> Void)?, remove: ((Row) -> Void)? = nil) {
        self.title = title
        self.searchable = searchable
        self.emptyText = emptyText
        self.hint = hint
        self.source = rows
        self.activate = activate
        self.remove = remove
    }

    /// `false` if the window could not be made; the owner then forgets the panel.
    func show(owner: HWND) -> Bool {
        let instance = GetModuleHandleW(nil)
        guard Self.register(instance: instance) else { return false }

        // A share of the browser window, with a floor and a ceiling — AGENTS.md's "sizes are
        // fractions of the viewport" — and centred across it, a little below the bar.
        var frame = RECT()
        GetWindowRect(owner, &frame)
        let dpi = GetDpiForWindow(owner)
        scale = dpi > 0 ? Double(dpi) / 96.0 : 1
        let ownerWidth = frame.right - frame.left
        let ownerHeight = frame.bottom - frame.top
        let width = min(max(Int32(Double(ownerWidth) * 0.45), px(440)), px(860))
        let height = min(max(Int32(Double(ownerHeight) * 0.7), px(360)), ownerHeight)
        let left = frame.left + (ownerWidth - width) / 2
        let top = frame.top + Int32(Double(ownerHeight) * 0.1)

        let created = Self.className.withCString(encodedAs: UTF16.self) { className in
            title.withCString(encodedAs: UTF16.self) { caption in
                CreateWindowExW(
                    0, className, caption,
                    DWORD(WS_POPUP) | DWORD(WS_CAPTION) | DWORD(WS_SYSMENU) | DWORD(WS_THICKFRAME) | DWORD(WS_CLIPCHILDREN),
                    left, top, width, height, owner, nil, instance,
                    Unmanaged.passUnretained(self).toOpaque()
                )
            }
        }
        guard let created else { return false }
        hwnd = created
        makeFonts()

        if searchable {
            searchHwnd = "EDIT".withCString(encodedAs: UTF16.self) { className in
                CreateWindowExW(0, className, nil, DWORD(WS_CHILD | WS_VISIBLE | ES_AUTOHSCROLL),
                                0, 0, 0, 0, created, nil, instance, nil)
            }
        }
        // `LBS_OWNERDRAWFIXED` without `LBS_HASSTRINGS`: an item's data is its index into `rows`,
        // which is all `WM_DRAWITEM` needs to draw it.
        let listStyle = WS_CHILD | WS_VISIBLE | WS_VSCROLL | LBS_NOTIFY | LBS_OWNERDRAWFIXED | LBS_NOINTEGRALHEIGHT
        listHwnd = "LISTBOX".withCString(encodedAs: UTF16.self) { className in
            CreateWindowExW(0, className, nil, DWORD(listStyle), 0, 0, 0, 0, created, nil, instance, nil)
        }
        for control in [searchHwnd, listHwnd] {
            guard let control, let uiFont else { continue }
            SendMessageW(control, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: Int(bitPattern: uiFont))), 1)
        }

        layout()
        reload()
        ShowWindow(created, SW_SHOWNORMAL)
        SetForegroundWindow(created)
        SetFocus(searchHwnd ?? listHwnd)
        return true
    }

    func close() {
        guard let hwnd else { return }
        DestroyWindow(hwnd)
    }

    /// The panel's keys, out of the queue before the `EDIT` or the `LISTBOX` sees them. `true`
    /// swallows the message.
    func route(_ message: MSG) -> Bool {
        guard let hwnd, let target = message.hwnd, target == hwnd || IsChild(hwnd, target),
              Int32(message.message) == WM_KEYDOWN else { return false }
        switch Int32(message.wParam) {
        case VK_ESCAPE:
            close()
            return true
        case VK_RETURN:
            activateSelection()
            return true
        case VK_DOWN where target == searchHwnd, VK_UP where target == searchHwnd:
            moveSelection(Int32(message.wParam) == VK_DOWN ? 1 : -1)
            return true
        case VK_DELETE where target == listHwnd && remove != nil:
            removeSelection()
            return true
        default:
            return false
        }
    }

    // MARK: Rows

    private func reload() {
        rows = source(query)
        guard let listHwnd else { return }
        SendMessageW(listHwnd, UINT(LB_RESETCONTENT), 0, 0)
        for index in rows.indices {
            SendMessageW(listHwnd, UINT(LB_ADDSTRING), 0, LPARAM(index))
        }
        if !rows.isEmpty { SendMessageW(listHwnd, UINT(LB_SETCURSEL), 0, 0) }
        ShowWindow(listHwnd, rows.isEmpty ? SW_HIDE : SW_SHOW)
        if let hwnd { InvalidateRect(hwnd, nil, true) }
    }

    /// The rows again, keeping the selection where it was — for a list whose rows change while it is
    /// open, which is what a download in progress is.
    func refresh() {
        let selected = selectedIndex
        reload()
        if let listHwnd, let selected, !rows.isEmpty {
            SendMessageW(listHwnd, UINT(LB_SETCURSEL), WPARAM(min(selected, rows.count - 1)), 0)
        }
    }

    private var query: String {
        guard let searchHwnd else { return "" }
        let length = Int(GetWindowTextLengthW(searchHwnd))
        var buffer = [WCHAR](repeating: 0, count: length + 1)
        _ = GetWindowTextW(searchHwnd, &buffer, Int32(buffer.count))
        return String(decoding: buffer.prefix(length), as: UTF16.self)
    }

    private var selectedIndex: Int? {
        guard let listHwnd, !rows.isEmpty else { return nil }
        let index = Int(SendMessageW(listHwnd, UINT(LB_GETCURSEL), 0, 0))
        return rows.indices.contains(index) ? index : 0
    }

    private func moveSelection(_ delta: Int) {
        guard let listHwnd, let current = selectedIndex else { return }
        let next = min(max(0, current + delta), rows.count - 1)
        SendMessageW(listHwnd, UINT(LB_SETCURSEL), WPARAM(next), 0)
    }

    private func activateSelection() {
        guard let activate, let index = selectedIndex else { return }
        activate(rows[index])
    }

    private func removeSelection() {
        guard let remove, let index = selectedIndex else { return }
        remove(rows[index])
        reload()
        if let listHwnd, !rows.isEmpty {
            SendMessageW(listHwnd, UINT(LB_SETCURSEL), WPARAM(min(index, rows.count - 1)), 0)
        }
    }

    // MARK: Layout and painting

    private func px(_ logical: Double) -> Int32 { Int32((logical * scale).rounded()) }

    private var searchPill: RECT {
        guard let hwnd, searchable else { return RECT() }
        var client = RECT()
        GetClientRect(hwnd, &client)
        let pad = px(12)
        return RECT(left: pad, top: pad, right: client.right - pad, bottom: pad + px(30))
    }

    private var hintRect: RECT {
        guard let hwnd else { return RECT() }
        var client = RECT()
        GetClientRect(hwnd, &client)
        return RECT(left: px(12), top: client.bottom - px(30), right: client.right - px(12), bottom: client.bottom)
    }

    private var listRect: RECT {
        guard let hwnd else { return RECT() }
        var client = RECT()
        GetClientRect(hwnd, &client)
        let top = searchable ? searchPill.bottom + px(10) : px(8)
        return RECT(left: 0, top: top, right: client.right, bottom: hintRect.top)
    }

    private func layout() {
        if let searchHwnd {
            let pill = searchPill
            let height = px(18)
            MoveWindow(searchHwnd, pill.left + px(10), pill.top + (pill.bottom - pill.top - height) / 2,
                       pill.right - pill.left - px(20), height, true)
        }
        if let listHwnd {
            let list = listRect
            MoveWindow(listHwnd, list.left, list.top, list.right - list.left, list.bottom - list.top, true)
        }
    }

    private func paint() {
        guard let hwnd else { return }
        var ps = PAINTSTRUCT()
        guard let hdc = BeginPaint(hwnd, &ps) else { return }
        defer { EndPaint(hwnd, &ps) }
        var client = RECT()
        GetClientRect(hwnd, &client)
        fill(hdc, client, RailWindow.backgroundColor)
        SetBkMode(hdc, TRANSPARENT)
        if searchable {
            let pill = searchPill
            let brush = CreateSolidBrush(RailWindow.addressFieldColor)
            let pen = CreatePen(Int32(PS_SOLID), 1, RailWindow.addressBorderColor)
            let previousBrush = SelectObject(hdc, brush)
            let previousPen = SelectObject(hdc, pen)
            RoundRect(hdc, pill.left, pill.top, pill.right, pill.bottom, px(16), px(16))
            SelectObject(hdc, previousBrush)
            SelectObject(hdc, previousPen)
            DeleteObject(brush)
            DeleteObject(pen)
        }
        // Wrapped, and so not vertically centred by `DrawText` — `DT_VCENTER` works on one line only
        // — but started a little above the middle, which reads as centred for a sentence or two. A
        // single line was cut off at both ends of a window narrower than the sentence.
        if rows.isEmpty {
            let list = listRect
            let middle = list.top + (list.bottom - list.top) / 2
            text(hdc, emptyText, in: RECT(left: list.left + px(32), top: middle - px(24),
                                          right: list.right - px(32), bottom: list.bottom),
                 font: uiFont, color: RailWindow.dimLabelColor, format: DT_CENTER | DT_WORDBREAK)
        }
        text(hdc, hint, in: hintRect, font: smallFont, color: RailWindow.dimLabelColor,
             format: DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS)
    }

    /// Two lines: what the row is, strong, and where, dim — the shape of the Mac's history rows.
    private func drawItem(_ item: DRAWITEMSTRUCT) {
        guard item.itemID != UINT.max, rows.indices.contains(Int(item.itemID)), let hdc = item.hDC else { return }
        let row = rows[Int(item.itemID)]
        let selected = (item.itemState & UINT(ODS_SELECTED)) != 0
        fill(hdc, item.rcItem, selected ? RailWindow.chipColor : RailWindow.backgroundColor)
        SetBkMode(hdc, TRANSPARENT)
        let rect = item.rcItem
        let middle = rect.top + (rect.bottom - rect.top) / 2
        text(hdc, row.title, in: RECT(left: rect.left + px(14), top: rect.top + px(4), right: rect.right - px(14), bottom: middle + px(1)),
             font: strongFont, color: RailWindow.textColor, format: DT_LEFT | DT_BOTTOM | DT_SINGLELINE | DT_END_ELLIPSIS)
        text(hdc, row.detail, in: RECT(left: rect.left + px(14), top: middle + px(2), right: rect.right - px(14), bottom: rect.bottom - px(4)),
             font: smallFont, color: RailWindow.labelColor, format: DT_LEFT | DT_TOP | DT_SINGLELINE | DT_END_ELLIPSIS)
    }

    private func fill(_ hdc: HDC, _ rect: RECT, _ color: COLORREF) {
        var rect = rect
        let brush = CreateSolidBrush(color)
        FillRect(hdc, &rect, brush)
        DeleteObject(brush)
    }

    private func text(_ hdc: HDC, _ string: String, in rect: RECT, font: HFONT?, color: COLORREF, format: Int32) {
        var rect = rect
        let previous = font.map { SelectObject(hdc, $0) }
        SetTextColor(hdc, color)
        string.withCString(encodedAs: UTF16.self) { _ = DrawTextW(hdc, $0, -1, &rect, UINT(format)) }
        if let previous { SelectObject(hdc, previous) }
    }

    private func makeFonts() {
        func font(_ size: Double, _ weight: Int32) -> HFONT? {
            "Segoe UI".withCString(encodedAs: UTF16.self) { face in
                CreateFontW(-Int32((size * scale).rounded()), 0, 0, 0, weight, 0, 0, 0,
                            DWORD(DEFAULT_CHARSET), DWORD(OUT_TT_PRECIS), DWORD(CLIP_DEFAULT_PRECIS),
                            DWORD(CLEARTYPE_QUALITY), DWORD(DEFAULT_PITCH | FF_DONTCARE), face)
            }
        }
        uiFont = font(14, FW_NORMAL)
        strongFont = font(13, FW_SEMIBOLD)
        smallFont = font(12, FW_NORMAL)
    }

    // MARK: Messages

    func handle(message: UINT, wParam: WPARAM, lParam: LPARAM) -> LRESULT? {
        switch Int32(message) {
        case WM_SIZE:
            layout()
            if let hwnd { InvalidateRect(hwnd, nil, true) }
            return 0
        case WM_ERASEBKGND:
            return 1
        case WM_PAINT:
            paint()
            return 0
        // Sent while the list box is being created, before it has a single row.
        case WM_MEASUREITEM:
            guard let item = UnsafeMutablePointer<MEASUREITEMSTRUCT>(bitPattern: Int(lParam)) else { return nil }
            item.pointee.itemHeight = UINT(px(48))
            return 1
        case WM_DRAWITEM:
            guard let item = UnsafeMutablePointer<DRAWITEMSTRUCT>(bitPattern: Int(lParam)) else { return nil }
            drawItem(item.pointee)
            return 1
        case WM_COMMAND:
            let code = Int32((wParam >> 16) & 0xFFFF)
            let control = UnsafeMutablePointer<HWND__>(bitPattern: Int(lParam))
            if control == searchHwnd, code == EN_CHANGE {
                reload()
                return 0
            }
            if control == listHwnd, code == LBN_DBLCLK {
                activateSelection()
                return 0
            }
            return nil
        case WM_CTLCOLOREDIT, WM_CTLCOLORLISTBOX:
            guard let hdc = UnsafeMutableRawPointer(bitPattern: UInt(wParam))?.assumingMemoryBound(to: HDC__.self) else { return nil }
            let isField = Int32(message) == WM_CTLCOLOREDIT
            let color = isField ? RailWindow.addressFieldColor : RailWindow.backgroundColor
            if isField, fieldBrush == nil { fieldBrush = CreateSolidBrush(color) }
            if !isField, backgroundBrush == nil { backgroundBrush = CreateSolidBrush(color) }
            SetTextColor(hdc, RailWindow.textColor)
            SetBkColor(hdc, color)
            guard let brush = isField ? fieldBrush : backgroundBrush else { return nil }
            return LRESULT(Int(bitPattern: UnsafeMutableRawPointer(brush)))
        case WM_CLOSE:
            close()
            return 0
        case WM_DESTROY:
            for object in [uiFont, strongFont, smallFont] where object != nil { DeleteObject(object) }
            for brush in [backgroundBrush, fieldBrush] where brush != nil { DeleteObject(brush) }
            // Before `onClose`, which may release the last reference to this object: the messages
            // still to come (`WM_NCDESTROY`) must not find a pointer to it in the window.
            if let hwnd { SixRailSetUserData(hwnd, nil) }
            hwnd = nil
            onClose?()
            return 0
        default:
            return nil
        }
    }

    private static func register(instance: HINSTANCE?) -> Bool {
        guard !registered else { return true }
        var wc = WNDCLASSEXW()
        wc.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
        wc.style = UINT(CS_HREDRAW | CS_VREDRAW)
        wc.lpfnWndProc = listPanelProc
        wc.hInstance = instance
        wc.hCursor = SixRailArrowCursor()
        let atom = className.withCString(encodedAs: UTF16.self) { name -> ATOM in
            wc.lpszClassName = name
            return RegisterClassExW(&wc)
        }
        registered = atom != 0
        return registered
    }
}

/// The same `GWLP_USERDATA` dance `railWindowProc` does, for the panel.
private nonisolated func listPanelProc(
    _ hwnd: HWND?, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM
) -> LRESULT {
    if Int32(message) == WM_NCCREATE {
        if let hwnd, let params = SixRailCreateParams(lParam) {
            SixRailSetUserData(hwnd, params)
        }
        return DefWindowProcW(hwnd, message, wParam, lParam)
    }
    guard let hwnd, let stored = SixRailGetUserData(hwnd) else {
        return DefWindowProcW(hwnd, message, wParam, lParam)
    }
    let panel = Unmanaged<RailListPanel>.fromOpaque(stored).takeUnretainedValue()
    let handled = MainActor.assumeIsolated {
        panel.handle(message: message, wParam: wParam, lParam: lParam)
    }
    return handled ?? DefWindowProcW(hwnd, message, wParam, lParam)
}
