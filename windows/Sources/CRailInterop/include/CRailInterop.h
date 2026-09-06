#ifndef SIX_CRAILINTEROP_H
#define SIX_CRAILINTEROP_H

#include <windows.h>
#include <windowsx.h>

// <windowsx.h>'s mouse/wheel macros are not something Swift can call, and the WM_NCCREATE /
// GWLP_USERDATA dance a WNDPROC needs is exactly the kind of pointer-sized-integer arithmetic
// that is easy to get subtly wrong translating by hand into Swift's WPARAM/LPARAM. Both live
// here instead, where the C compiler is the one checking the types, and Swift only ever sees a
// plain `Int32` or `UnsafeMutableRawPointer?`.

static inline int SixRailPointX(LPARAM lParam) { return GET_X_LPARAM(lParam); }
static inline int SixRailPointY(LPARAM lParam) { return GET_Y_LPARAM(lParam); }
static inline int SixRailLoWord(LPARAM lParam) { return LOWORD(lParam); }
static inline int SixRailHiWord(LPARAM lParam) { return HIWORD(lParam); }
static inline int SixRailWheelDelta(WPARAM wParam) { return GET_WHEEL_DELTA_WPARAM(wParam); }
static inline BOOL SixRailKeyDown(int virtualKey) { return GetKeyState(virtualKey) < 0; }
// The scan code (Set 1) in WM_KEYDOWN's lParam, bits 16-23 — the physical key, the same one
// regardless of the active keyboard layout. `KeyBindings`' letter bindings want this, not the
// virtual-key code: see CLAUDE.md's note on `⌥W` reporting «ц» on a Russian layout.
static inline int SixRailScanCode(LPARAM lParam) { return (int)((lParam >> 16) & 0xFF); }

// The instance a `WNDPROC` belongs to travels through `GWLP_USERDATA`: set from `CREATESTRUCTW`
// on `WM_NCCREATE`, read back on every message after it.
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
