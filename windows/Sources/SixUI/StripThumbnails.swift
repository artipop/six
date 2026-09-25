import Foundation
import SixBrowser
@testable import SixCore
import WinSDK

/// A picture of a page, so a column that has given up its `WKView` still has something to show —
/// the overview above all, which is every column at once and would otherwise be a wall of coloured
/// rectangles after a relaunch. The Mac and Linux keep the same pictures for the same reason.
///
/// Taken with `PrintWindow(PW_RENDERFULLCONTENT)` on the view's own `HWND`, which is the call that
/// captures a WebKit child without it being on top and without touching focus (docs/windows.md, for
/// the harness that found it). A view can only be photographed while it is on screen, so this is
/// done on the way *out* — just before a view is hidden or discarded — and a moment after a page
/// finishes loading.
///
/// Kept at half the view's pixels: the pictures are drawn at overview scale, which is a half at most.
extension StripWindow {
    /// `PW_RENDERFULLCONTENT`, which `WinUser.h` defines only for `_WIN32_WINNT >= 0x0603`.
    private static let renderFullContent: UINT = 2

    func captureThumbnail(_ tabID: Foundation.UUID) {
        guard let view = webViews[tabID], let child = view.hwnd, IsWindowVisible(child) else { return }
        var bounds = RECT()
        GetClientRect(child, &bounds)
        let width = bounds.right - bounds.left
        let height = bounds.bottom - bounds.top
        guard width > 8, height > 8, let screen = GetDC(nil) else { return }
        defer { ReleaseDC(nil, screen) }

        guard let fullDC = CreateCompatibleDC(screen), let full = CreateCompatibleBitmap(screen, width, height) else { return }
        let previousFull = SelectObject(fullDC, full)
        let printed = PrintWindow(child, fullDC, Self.renderFullContent)

        let smallWidth = max(1, width / 2)
        let smallHeight = max(1, height / 2)
        var small: HBITMAP?
        if printed, let smallDC = CreateCompatibleDC(screen), let bitmap = CreateCompatibleBitmap(screen, smallWidth, smallHeight) {
            let previousSmall = SelectObject(smallDC, bitmap)
            SetStretchBltMode(smallDC, HALFTONE)
            SetBrushOrgEx(smallDC, 0, 0, nil)
            StretchBlt(smallDC, 0, 0, smallWidth, smallHeight, fullDC, 0, 0, width, height, DWORD(SRCCOPY))
            SelectObject(smallDC, previousSmall)
            DeleteDC(smallDC)
            small = bitmap
        }
        SelectObject(fullDC, previousFull)
        DeleteObject(full)
        DeleteDC(fullDC)

        guard let small else { return }
        // A capture that came back all zeros is a view that had not drawn anything yet — keeping it
        // would replace a good picture with a black one.
        guard let pixels = Self.pixels(of: small, width: smallWidth, height: smallHeight, screen: screen),
              pixels.contains(where: { $0 != 0 }) else {
            DeleteObject(small)
            return
        }
        if let old = thumbnails[tabID] { DeleteObject(old) }
        thumbnails[tabID] = small
        missingThumbnails.remove(tabID)
        Self.writeBitmap(pixels, width: smallWidth, height: smallHeight, to: model.thumbnailPath(for: tabID))
    }

    /// Every view on screen right now — before the overview hides them all, and before the window
    /// closes, so the next launch has pictures for its first overview.
    func captureVisibleThumbnails() {
        for id in visibleViews { captureThumbnail(id) }
    }

    /// The picture for a column: from memory, or from the file a previous run left. A column with no
    /// file is remembered as having none, so a repaint does not go to the disk to find that out again.
    func thumbnail(for tabID: Foundation.UUID) -> HBITMAP? {
        if let cached = thumbnails[tabID] { return cached }
        guard !missingThumbnails.contains(tabID) else { return nil }
        let path = model.thumbnailPath(for: tabID)
        let handle: HANDLE? = FileManager.default.fileExists(atPath: path)
            ? path.withCString(encodedAs: UTF16.self) {
                LoadImageW(nil, $0, UINT(IMAGE_BITMAP), 0, 0, UINT(LR_LOADFROMFILE | LR_CREATEDIBSECTION))
            }
            : nil
        guard let handle else {
            missingThumbnails.insert(tabID)
            return nil
        }
        let bitmap = handle.assumingMemoryBound(to: HBITMAP__.self)
        thumbnails[tabID] = bitmap
        return bitmap
    }

    func forgetThumbnail(_ tabID: Foundation.UUID) {
        if let bitmap = thumbnails[tabID] { DeleteObject(bitmap) }
        thumbnails[tabID] = nil
        missingThumbnails.remove(tabID)
    }

    /// Drawn to cover the rectangle and cut from the *top*: the top of a page is what identifies it,
    /// and a picture squeezed to fit a card of another shape reads as a different page.
    func drawThumbnail(_ hdc: HDC, _ bitmap: HBITMAP, into rect: RECT) {
        let targetWidth = rect.right - rect.left
        let targetHeight = rect.bottom - rect.top
        guard targetWidth > 0, targetHeight > 0, let memoryDC = CreateCompatibleDC(hdc) else { return }
        var info = BITMAP()
        GetObjectW(bitmap, Int32(MemoryLayout<BITMAP>.size), &info)
        guard info.bmWidth > 0, info.bmHeight > 0 else {
            DeleteDC(memoryDC)
            return
        }
        var sourceWidth = info.bmWidth
        var sourceHeight = Int32(Double(info.bmWidth) * Double(targetHeight) / Double(targetWidth))
        if sourceHeight > info.bmHeight {
            sourceHeight = info.bmHeight
            sourceWidth = Int32(Double(info.bmHeight) * Double(targetWidth) / Double(targetHeight))
        }
        let previous = SelectObject(memoryDC, bitmap)
        SetStretchBltMode(hdc, HALFTONE)
        SetBrushOrgEx(hdc, 0, 0, nil)
        StretchBlt(hdc, rect.left, rect.top, targetWidth, targetHeight,
                   memoryDC, (info.bmWidth - sourceWidth) / 2, 0, sourceWidth, sourceHeight, DWORD(SRCCOPY))
        SelectObject(memoryDC, previous)
        DeleteDC(memoryDC)
    }

    // MARK: The file

    /// 32 bits a pixel, bottom-up, the layout `GetDIBits` hands out and a BMP stores. The bitmap
    /// must not be selected into a DC while this runs.
    private static func pixels(of bitmap: HBITMAP, width: Int32, height: Int32, screen: HDC) -> [UInt8]? {
        var info = BITMAPINFO()
        info.bmiHeader = header(width: width, height: height)
        var pixels = [UInt8](repeating: 0, count: Int(width) * Int(height) * 4)
        let lines = GetDIBits(screen, bitmap, 0, UINT(height), &pixels, &info, UINT(DIB_RGB_COLORS))
        return lines == height ? pixels : nil
    }

    private static func header(width: Int32, height: Int32) -> BITMAPINFOHEADER {
        var header = BITMAPINFOHEADER()
        header.biSize = DWORD(MemoryLayout<BITMAPINFOHEADER>.size)
        header.biWidth = width
        header.biHeight = height
        header.biPlanes = 1
        header.biBitCount = 32
        header.biCompression = DWORD(BI_RGB)
        header.biSizeImage = DWORD(Int(width) * Int(height) * 4)
        return header
    }

    /// Written byte by byte rather than through `BITMAPFILEHEADER`, whose 14 bytes depend on a
    /// `#pragma pack(2)` the importer may or may not have kept.
    private static func writeBitmap(_ pixels: [UInt8], width: Int32, height: Int32, to path: String) {
        var data = Data([0x42, 0x4D]) // "BM"
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let offset = UInt32(14 + MemoryLayout<BITMAPINFOHEADER>.size)
        append(offset + UInt32(pixels.count))
        append(UInt16(0))
        append(UInt16(0))
        append(offset)
        var header = header(width: width, height: height)
        withUnsafeBytes(of: &header) { data.append(contentsOf: $0) }
        data.append(contentsOf: pixels)
        do {
            try data.write(to: URL(fileURLWithPath: path))
        } catch {
            Log.error(.pages, "could not write \(path): \(error)")
        }
    }
}
