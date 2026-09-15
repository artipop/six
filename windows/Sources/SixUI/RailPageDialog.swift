import CRailInterop
import Foundation
import SixBrowser
@testable import SixCore
import WinSDK

/// A page's own `alert()`, `confirm()` or `prompt()`, in a window of its own.
///
/// The Mac puts these up as a sheet on the strip's one window, saying which site is speaking
/// (`PageDialogs`); this is that sheet, as an owned popup over the rail, with the site in its caption.
/// Not `MessageBoxW`, for two reasons. `prompt()` needs a field, and Windows has no input box to give
/// it. And a message box is a modal loop: while it is up nothing drains the main queue (`RailLoop`),
/// so every `Task` in the browser — a translation, an embedding — would stop along with the one page
/// that asked. WebKit keeps that page's JavaScript suspended until the listener is called, which is
/// all "modal" ever meant for `alert()`; the rest of the browser carries on.
///
/// `Enter` is OK and `Esc` is Cancel, taken out of the queue by `route` the way the list panel's are.
@MainActor
final class RailPageDialog {
    typealias Kind = RailWebView.PageDialog.Kind

    private(set) var hwnd: HWND?
    private var fieldHwnd: HWND?
    private var owner: HWND?
    private let host: String
    private let message: String
    private let kind: Kind
    private let accent: COLORREF
    /// `nil` is Cancel. Called exactly once; the window is gone by then.
    private var finish: ((String?) -> Void)?

    private var scale: Double = 1
    private var textFont: HFONT?
    private var buttonFont: HFONT?
    private var fieldBrush: HBRUSH?
    private var messageHeight: Int32 = 0

    private static let className = "SixPageDialog"
    private static var registered = false

    private static let padding: Double = 20
    private static let gap: Double = 14
    private static let fieldHeight: Double = 32
    private static let buttonHeight: Double = 32
    private static let buttonWidth: Double = 92

    init(host: String, message: String, kind: Kind, accent: COLORREF, finish: @escaping (String?) -> Void) {
        self.host = host
        self.message = message
        self.kind = kind
        self.accent = accent
        self.finish = finish
    }

    private var isPrompt: Bool {
        if case .prompt = kind { return true }
        return false
    }

    /// An alert has one button, and closing it any way at all is that button.
    private var hasCancel: Bool {
        if case .alert = kind { return false }
        return true
    }

    /// `false` if the window could not be made; the owner then answers Cancel for it.
    func show(owner: HWND) -> Bool {
        let instance = GetModuleHandleW(nil)
        guard Self.register(instance: instance) else { return false }
        self.owner = owner

        var frame = RECT()
        GetWindowRect(owner, &frame)
        let dpi = GetDpiForWindow(owner)
        scale = dpi > 0 ? Double(dpi) / 96.0 : 1
        makeFonts()

        // A share of the browser window with a floor and a ceiling, like the list panel; as tall as
        // the message needs, up to half the window — a page that alerts a novel gets it clipped.
        let ownerWidth = frame.right - frame.left
        let ownerHeight = frame.bottom - frame.top
        let width = min(max(Int32(Double(ownerWidth) * 0.34), px(380)), px(640))
        messageHeight = min(measure(message, width: width - 2 * px(Self.padding)), Int32(Double(ownerHeight) * 0.5))
        var outer = RECT(left: 0, top: 0, right: width, bottom: clientHeight)
        let style = DWORD(WS_POPUP) | DWORD(WS_CAPTION) | DWORD(WS_SYSMENU)
        AdjustWindowRectExForDpi(&outer, style, false, 0, dpi)
        let outerWidth = outer.right - outer.left
        let outerHeight = outer.bottom - outer.top
        let left = frame.left + (ownerWidth - outerWidth) / 2
        let top = frame.top + Int32(Double(ownerHeight) * 0.18)

        let caption = "\(host) says"
        let created = Self.className.withCString(encodedAs: UTF16.self) { className in
            caption.withCString(encodedAs: UTF16.self) { title in
                CreateWindowExW(0, className, title, style | DWORD(WS_CLIPCHILDREN),
                                left, top, outerWidth, outerHeight, owner, nil, instance,
                                Unmanaged.passUnretained(self).toOpaque())
            }
        }
        guard let created else { return false }
        hwnd = created

        if case .prompt(let defaultText) = kind {
            fieldHwnd = "EDIT".withCString(encodedAs: UTF16.self) { className in
                CreateWindowExW(0, className, nil, DWORD(WS_CHILD | WS_VISIBLE | ES_AUTOHSCROLL),
                                0, 0, 0, 0, created, nil, instance, nil)
            }
            if let fieldHwnd {
                if let textFont {
                    SendMessageW(fieldHwnd, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: Int(bitPattern: textFont))), 1)
                }
                _ = defaultText.withCString(encodedAs: UTF16.self) { SetWindowTextW(fieldHwnd, $0) }
                // Selected, so typing replaces what the page offered — the way every browser's prompt does.
                SendMessageW(fieldHwnd, UINT(EM_SETSEL), 0, -1)
            }
        }
        layout()
        ShowWindow(created, SW_SHOWNORMAL)
        SetForegroundWindow(created)
        SetFocus(fieldHwnd ?? created)
        return true
    }

    /// Closes the dialog as its Cancel — the column went away, or the browser is closing.
    func dismiss() {
        complete(hasCancel ? nil : "")
    }

    /// `true` swallows the message.
    func route(_ message: MSG) -> Bool {
        guard let hwnd, let target = message.hwnd, target == hwnd || IsChild(hwnd, target),
              Int32(message.message) == WM_KEYDOWN else { return false }
        switch Int32(message.wParam) {
        case VK_RETURN:
            complete(okValue)
            return true
        case VK_ESCAPE:
            dismiss()
            return true
        default:
            return false
        }
    }

    // MARK: Answering

    private var okValue: String {
        guard let fieldHwnd else { return "" }
        let length = Int(GetWindowTextLengthW(fieldHwnd))
        var buffer = [WCHAR](repeating: 0, count: length + 1)
        _ = GetWindowTextW(fieldHwnd, &buffer, Int32(buffer.count))
        return String(decoding: buffer.prefix(length), as: UTF16.self)
    }

    /// The window first, then the rail back in front, then the answer — which may put up the next
    /// question in the queue, and that one should not open behind a window about to be destroyed.
    private func complete(_ value: String?) {
        guard let callback = finish else { return }
        finish = nil
        if let hwnd { DestroyWindow(hwnd) }
        if let owner { SetForegroundWindow(owner) }
        callback(value)
    }

    // MARK: Layout and painting

    private func px(_ logical: Double) -> Int32 { Int32((logical * scale).rounded()) }

    private var clientHeight: Int32 {
        px(Self.padding) + messageHeight + px(Self.gap)
            + (isPrompt ? px(Self.fieldHeight) + px(Self.gap) : 0)
            + px(Self.buttonHeight) + px(Self.padding)
    }

    private var client: RECT {
        var rect = RECT()
        if let hwnd { GetClientRect(hwnd, &rect) }
        return rect
    }

    private var messageRect: RECT {
        let pad = px(Self.padding)
        return RECT(left: pad, top: pad, right: client.right - pad, bottom: pad + messageHeight)
    }

    private var fieldPill: RECT {
        let top = messageRect.bottom + px(Self.gap)
        return RECT(left: px(Self.padding), top: top, right: client.right - px(Self.padding), bottom: top + px(Self.fieldHeight))
    }

    private var okButton: RECT {
        let right = client.right - px(Self.padding)
        let bottom = client.bottom - px(Self.padding)
        return RECT(left: right - px(Self.buttonWidth), top: bottom - px(Self.buttonHeight), right: right, bottom: bottom)
    }

    private var cancelButton: RECT {
        let ok = okButton
        return RECT(left: ok.left - px(8) - px(Self.buttonWidth), top: ok.top, right: ok.left - px(8), bottom: ok.bottom)
    }

    private func measure(_ text: String, width: Int32) -> Int32 {
        guard let dc = GetDC(nil) else { return px(20) }
        defer { ReleaseDC(nil, dc) }
        let previous = textFont.map { SelectObject(dc, $0) }
        var rect = RECT(left: 0, top: 0, right: width, bottom: 0)
        _ = text.withCString(encodedAs: UTF16.self) {
            DrawTextW(dc, $0, -1, &rect, UINT(DT_CALCRECT | DT_WORDBREAK | DT_EDITCONTROL | DT_NOPREFIX))
        }
        if let previous { SelectObject(dc, previous) }
        return max(rect.bottom - rect.top, px(18))
    }

    private func layout() {
        guard let fieldHwnd else { return }
        let pill = fieldPill
        let height = px(18)
        MoveWindow(fieldHwnd, pill.left + px(10), pill.top + (pill.bottom - pill.top - height) / 2,
                   pill.right - pill.left - px(20), height, true)
    }

    private func paint() {
        guard let hwnd else { return }
        var ps = PAINTSTRUCT()
        guard let hdc = BeginPaint(hwnd, &ps) else { return }
        defer { EndPaint(hwnd, &ps) }
        fill(hdc, client, RailWindow.backgroundColor)
        SetBkMode(hdc, TRANSPARENT)
        // `DT_NOPREFIX`: a page's `&` is an ampersand, not a mnemonic.
        text(hdc, message, in: messageRect, font: textFont, color: RailWindow.textColor,
             format: DT_LEFT | DT_WORDBREAK | DT_EDITCONTROL | DT_NOPREFIX)
        if isPrompt {
            roundedRect(hdc, fieldPill, fill: RailWindow.addressFieldColor, border: RailWindow.addressBorderColor)
        }
        if hasCancel {
            roundedRect(hdc, cancelButton, fill: RailWindow.chipColor, border: RailWindow.addressBorderColor)
            text(hdc, "Cancel", in: cancelButton, font: buttonFont, color: RailWindow.textColor,
                 format: DT_CENTER | DT_VCENTER | DT_SINGLELINE)
        }
        roundedRect(hdc, okButton, fill: accent, border: accent)
        text(hdc, "OK", in: okButton, font: buttonFont, color: RailWindow.rgb(255, 255, 255),
             format: DT_CENTER | DT_VCENTER | DT_SINGLELINE)
    }

    private func fill(_ hdc: HDC, _ rect: RECT, _ color: COLORREF) {
        var rect = rect
        let brush = CreateSolidBrush(color)
        FillRect(hdc, &rect, brush)
        DeleteObject(brush)
    }

    private func roundedRect(_ hdc: HDC, _ rect: RECT, fill: COLORREF, border: COLORREF) {
        let brush = CreateSolidBrush(fill)
        let pen = CreatePen(Int32(PS_SOLID), 1, border)
        let previousBrush = SelectObject(hdc, brush)
        let previousPen = SelectObject(hdc, pen)
        RoundRect(hdc, rect.left, rect.top, rect.right, rect.bottom, px(12), px(12))
        SelectObject(hdc, previousBrush)
        SelectObject(hdc, previousPen)
        DeleteObject(brush)
        DeleteObject(pen)
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
        textFont = font(14, FW_NORMAL)
        buttonFont = font(13, FW_SEMIBOLD)
    }

    // MARK: Messages

    func handle(message: UINT, wParam: WPARAM, lParam: LPARAM) -> LRESULT? {
        switch Int32(message) {
        case WM_ERASEBKGND:
            return 1
        case WM_PAINT:
            paint()
            return 0
        case WM_LBUTTONUP:
            let x = SixRailPointX(lParam)
            let y = SixRailPointY(lParam)
            if okButton.contains(x: Int(x), y: Int(y)) {
                complete(okValue)
            } else if hasCancel, cancelButton.contains(x: Int(x), y: Int(y)) {
                dismiss()
            }
            return 0
        case WM_CTLCOLOREDIT:
            guard let hdc = UnsafeMutableRawPointer(bitPattern: UInt(wParam))?.assumingMemoryBound(to: HDC__.self) else { return nil }
            if fieldBrush == nil { fieldBrush = CreateSolidBrush(RailWindow.addressFieldColor) }
            SetTextColor(hdc, RailWindow.textColor)
            SetBkColor(hdc, RailWindow.addressFieldColor)
            guard let fieldBrush else { return nil }
            return LRESULT(Int(bitPattern: UnsafeMutableRawPointer(fieldBrush)))
        case WM_CLOSE:
            dismiss()
            return 0
        case WM_DESTROY:
            for object in [textFont, buttonFont] where object != nil { DeleteObject(object) }
            if let fieldBrush { DeleteObject(fieldBrush) }
            if let hwnd { SixRailSetUserData(hwnd, nil) }
            hwnd = nil
            // Destroyed from outside — its owner going away — without having been answered.
            if let callback = finish {
                finish = nil
                callback(hasCancel ? nil : "")
            }
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
        wc.lpfnWndProc = pageDialogProc
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

/// The same `GWLP_USERDATA` dance `listPanelProc` does, for the dialog.
private nonisolated func pageDialogProc(
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
    let dialog = Unmanaged<RailPageDialog>.fromOpaque(stored).takeUnretainedValue()
    let handled = MainActor.assumeIsolated {
        dialog.handle(message: message, wParam: wParam, lParam: lParam)
    }
    return handled ?? DefWindowProcW(hwnd, message, wParam, lParam)
}

/// A dialog waiting its turn: one is on screen at a time, the way the phone's `PageDialogQueue` has it,
/// and a second page asking waits for the first to be answered.
struct QueuedPageDialog {
    let tabID: Foundation.UUID
    let dialog: RailWebView.PageDialog
}

extension RailWindow {
    /// A page asked. Its dialog goes on screen now, or after the one already there is answered.
    func askPage(_ dialog: RailWebView.PageDialog, tabID: Foundation.UUID) {
        // What kind, from where and how long — never the words. A page's alert can carry a one-time
        // code, and a log is a file anyone debugging six gets sent.
        Log.info(.pages, "page dialog: \(Self.name(of: dialog.kind)) from \(dialog.host), \(dialog.message.count) characters, \(waitingDialogs.count) waiting, \(pageDialog == nil ? "none" : "one") on screen")
        waitingDialogs.append(QueuedPageDialog(tabID: tabID, dialog: dialog))
        showNextPageDialog()
    }

    private func showNextPageDialog() {
        guard pageDialog == nil, let hwnd, !waitingDialogs.isEmpty else { return }
        let next = waitingDialogs.removeFirst()
        let window = RailPageDialog(
            host: next.dialog.host, message: next.dialog.message, kind: next.dialog.kind,
            accent: Self.color(hex: model.profile(of: next.tabID).colorHex)
        ) { [weak self] value in
            Log.info(.pages, "page dialog: \(Self.name(of: next.dialog.kind)) answered \(value == nil ? "Cancel" : "OK")")
            next.dialog.answer(value)
            guard let self else { return }
            pageDialog = nil
            pageDialogTab = nil
            showNextPageDialog()
        }
        pageDialog = window
        pageDialogTab = next.tabID
        if !window.show(owner: hwnd) {
            pageDialog = nil
            pageDialogTab = nil
            next.dialog.answer(nil)
            showNextPageDialog()
        }
    }

    /// The kind alone: `prompt(defaultText:)` described by Swift would put the page's text in the log.
    private static func name(of kind: RailWebView.PageDialog.Kind) -> String {
        switch kind {
        case .alert: "alert"
        case .confirm: "confirm"
        case .prompt: "prompt"
        }
    }

    /// The column's page is going away: whatever it asked is answered Cancel, on screen or waiting.
    func forgetPageDialogs(for tabID: Foundation.UUID) {
        let leaving = waitingDialogs.filter { $0.tabID == tabID }
        waitingDialogs.removeAll { $0.tabID == tabID }
        for entry in leaving { entry.dialog.answer(nil) }
        if pageDialogTab == tabID { pageDialog?.dismiss() }
    }

    /// The browser is closing.
    func dismissPageDialogs() {
        let leaving = waitingDialogs
        waitingDialogs.removeAll()
        for entry in leaving { entry.dialog.answer(nil) }
        pageDialog?.dismiss()
    }

    /// `<input type=file>`: the system's own picker, owned by the rail.
    ///
    /// Out of WebKit's callback before it opens. The picker is a modal loop of its own, and running
    /// it inside a callback WebKit is still in the middle of delivering is asking for the kind of
    /// re-entrancy nobody has measured; one turn of the main queue later it is an ordinary click.
    /// Folders (`webkitdirectory`) are refused for now: the picker that chooses one is the COM
    /// `IFileOpenDialog`, which this front has no plumbing for yet.
    func chooseFiles(_ choice: RailWebView.FileChoice, tabID: Foundation.UUID) {
        let host = URL(string: model.url(for: tabID))?.host() ?? "This page"
        DispatchQueue.main.async { [weak self] in
            guard let self, let hwnd else { return choice.answer(nil) }
            guard !choice.allowsDirectories else {
                Log.info(.pages, "\(host) asked for a folder; the folder picker is not built yet")
                return choice.answer(nil)
            }
            let chosen = Self.openFiles(owner: hwnd, title: "\(host) is asking for a file",
                                        multiple: choice.allowsMultiple, extensions: choice.extensions)
            // How many and nothing more: a path names a person's files.
            Log.info(.pages, "file picker for \(host): \(chosen.map { "\($0.count) chosen" } ?? "cancelled")")
            choice.answer(chosen)
        }
    }

    /// `GetOpenFileNameW`, through `SixRailOpenFiles`. `nil` is Cancel.
    private static func openFiles(owner: HWND, title: String, multiple: Bool, extensions: [String]) -> [URL]? {
        // The filter is pairs of NUL-terminated strings — a label, then its patterns — ending in an
        // extra NUL. What the input accepts first, so it is the one selected; everything second,
        // because `accept` is a hint to the picker and not a rule a person can be held to.
        var filter: [WCHAR] = []
        func add(_ string: String) { filter += Array(string.utf16) + [0] }
        let patterns = extensions.map { "*.\($0)" }.joined(separator: ";")
        if !patterns.isEmpty {
            add("Accepted files (\(patterns))")
            add(patterns)
        }
        add("All files (*.*)")
        add("*.*")
        filter.append(0)

        var buffer = [WCHAR](repeating: 0, count: 32_768)
        let chosen = filter.withUnsafeBufferPointer { filterPointer in
            buffer.withUnsafeMutableBufferPointer { bufferPointer in
                title.withCString(encodedAs: UTF16.self) { caption in
                    SixRailOpenFiles(owner, caption, filterPointer.baseAddress, multiple ? 1 : 0,
                                     bufferPointer.baseAddress, DWORD(bufferPointer.count))
                }
            }
        }
        guard chosen != 0 else { return nil }

        // One file is one full path. Several are the folder, then each name, NUL-separated, and an
        // empty string where the list ends.
        var parts: [String] = []
        var start = 0
        for index in buffer.indices where buffer[index] == 0 {
            if index == start { break }
            parts.append(String(decoding: buffer[start..<index], as: UTF16.self))
            start = index + 1
        }
        guard let first = parts.first else { return nil }
        guard parts.count > 1 else { return [URL(fileURLWithPath: first)] }
        let folder = URL(fileURLWithPath: first, isDirectory: true)
        return parts.dropFirst().map { folder.appendingPathComponent($0) }
    }
}
