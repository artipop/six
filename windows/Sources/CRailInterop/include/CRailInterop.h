#ifndef SIX_CRAILINTEROP_H
#define SIX_CRAILINTEROP_H

#include <windows.h>
#include <windowsx.h>

// Win32 pieces Swift cannot reach: <windowsx.h>'s macros, three ClangImporter rough edges, and the
// WPARAM/LPARAM arithmetic that is easy to get subtly wrong by hand. Wrapped here so the C compiler
// is the one checking the types.

static inline int SixRailPointX(LPARAM lParam) { return GET_X_LPARAM(lParam); }
static inline int SixRailPointY(LPARAM lParam) { return GET_Y_LPARAM(lParam); }
static inline int SixRailLoWord(LPARAM lParam) { return LOWORD(lParam); }
static inline int SixRailHiWord(LPARAM lParam) { return HIWORD(lParam); }
static inline int SixRailWheelDelta(WPARAM wParam) { return GET_WHEEL_DELTA_WPARAM(wParam); }
// `int`, not `BOOL`: this SDK overlay imports `BOOL`-returning functions as Swift `Bool`, which
// makes the tri-state Win32 idiom (`< 0`, `!= 0`) stop type-checking.
static inline int SixRailKeyDown(int virtualKey) { return GetKeyState(virtualKey) < 0; }
// The Set 1 scan code in WM_KEYDOWN's lParam: the physical key, the same on every layout. See
// `RailKeyInput.railKey` for why the letter bindings want this and not the virtual-key code.
static inline int SixRailScanCode(LPARAM lParam) { return (int)((lParam >> 16) & 0xFF); }

// `IDC_ARROW` expands to `MAKEINTRESOURCE(32512)` — an integer disguised as a string pointer — which
// ClangImporter refuses to import ("structure not supported"). `MAKEINTRESOURCEW` explicitly, since
// the bare macro resolves to the ANSI form without `UNICODE` defined and `LoadCursorW` wants
// `LPCWSTR`, even though the bit pattern is identical either way.
static inline HCURSOR SixRailArrowCursor(void) { return LoadCursorW(NULL, MAKEINTRESOURCEW(32512)); }

// The other direction from SixRailPointX/Y: pack two shorts back into an LPARAM, for a window
// procedure that rewrites a message's coordinates before passing it on.
static inline LPARAM SixRailMakePoint(int x, int y) {
    return MAKELPARAM((WORD)x, (WORD)y);
}

// The instance a `WNDPROC` belongs to, travelling through `GWLP_USERDATA`.
static inline void *SixRailCreateParams(LPARAM lParam) {
    return ((CREATESTRUCTW *)lParam)->lpCreateParams;
}
static inline void SixRailSetUserData(HWND hwnd, void *data) {
    SetWindowLongPtrW(hwnd, GWLP_USERDATA, (LONG_PTR)data);
}
static inline void *SixRailGetUserData(HWND hwnd) {
    return (void *)GetWindowLongPtrW(hwnd, GWLP_USERDATA);
}

#endif
