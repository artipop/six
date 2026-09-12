#ifndef SIX_CRAILINTEROP_H
#define SIX_CRAILINTEROP_H

#include <windows.h>
#include <windowsx.h>
#include <commdlg.h>

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
// `IDC_HAND` (32649), for the same reason: the pointing hand over the top bar's buttons.
static inline HCURSOR SixRailHandCursor(void) { return LoadCursorW(NULL, MAKEINTRESOURCEW(32649)); }

// The other direction from SixRailLoWord/HiWord: pack two words back into an LPARAM, for a window
// procedure that rewrites a message before passing it on.
static inline LPARAM SixRailPackWords(int low, int high) {
    return MAKELPARAM((WORD)low, (WORD)high);
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

// `TrackPopupMenu` is declared `BOOL`, and with `TPM_RETURNCMD` it returns the chosen command id
// through that same return value — which this SDK overlay imports as Swift `Bool`, throwing the id
// away. Same rough edge as `SixRailKeyDown` above, same answer: keep it an `int`.
static inline int SixRailTrackPopupMenu(HMENU menu, unsigned flags, int x, int y, HWND owner) {
    return (int)TrackPopupMenu(menu, flags, x, y, 0, owner, NULL);
}

// `GetOpenFileNameW`, filled in here because `OPENFILENAMEW` is twenty-odd fields Swift would have to
// zero and spell out, and its flags are macros. `buffer` comes back as one full path, or — several
// chosen, under `OFN_EXPLORER` — the folder, then each name, NUL-separated, ending in two NULs.
// `int` for the reason `SixRailKeyDown` gives.
static inline int SixRailOpenFiles(HWND owner, LPCWSTR title, LPCWSTR filter, int multiple,
                                   LPWSTR buffer, DWORD capacity) {
    OPENFILENAMEW dialog;
    ZeroMemory(&dialog, sizeof dialog);
    dialog.lStructSize = sizeof dialog;
    dialog.hwndOwner = owner;
    dialog.lpstrTitle = title;
    dialog.lpstrFilter = filter;
    dialog.lpstrFile = buffer;
    dialog.nMaxFile = capacity;
    dialog.Flags = OFN_EXPLORER | OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_HIDEREADONLY | OFN_NOCHANGEDIR
        | (multiple ? OFN_ALLOWMULTISELECT : 0);
    buffer[0] = 0;
    return GetOpenFileNameW(&dialog) ? 1 : 0;
}

#endif
