#pragma once
#include <windows.h>
#include <dwmapi.h>
#include <algorithm>
#include <string>
#include <vector>

namespace theme {

constexpr COLORREF kBg = RGB(35, 39, 42);
constexpr COLORREF kPanel = RGB(41, 46, 50);
constexpr COLORREF kBorder = RGB(58, 66, 74);
constexpr COLORREF kText = RGB(128, 224, 245);
constexpr COLORREF kMuted = RGB(173, 176, 179);
constexpr COLORREF kError = RGB(242, 63, 67);
constexpr COLORREF kHover = RGB(52, 74, 82);

struct Resources {
  HBRUSH bg = nullptr;
  HBRUSH panel = nullptr;
  HFONT font = nullptr;
  HFONT big = nullptr;
};

inline Resources& res() {
  static Resources r;
  return r;
}

inline void init() {
  Resources& r = res();
  if (r.bg) return;
  r.bg = CreateSolidBrush(kBg);
  r.panel = CreateSolidBrush(kPanel);
  r.font = CreateFontW(-15, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
  r.big = CreateFontW(-26, 0, 0, 0, FW_BLACK, FALSE, FALSE, FALSE, DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
}

inline void dark_title(HWND hwnd) {
  BOOL dark = TRUE;
  DwmSetWindowAttribute(hwnd, 20, &dark, sizeof(dark));
}

enum class Look { Normal, Accent, Selected };

inline void paint_button(HDC dc, RECT r, const std::wstring& label, Look look, bool disabled, bool pressed, bool arrow = false, bool hover = false) {
  FillRect(dc, &r, res().bg);
  COLORREF fill = look == Look::Accent ? (pressed ? RGB(100, 190, 215) : (hover ? RGB(160, 235, 250) : kText))
                                       : (look == Look::Selected ? RGB(50, 76, 86) : (pressed ? kBorder : (hover ? kHover : kPanel)));
  COLORREF edge = look == Look::Normal ? (hover ? kText : kBorder) : kText;
  COLORREF text = look == Look::Accent ? kBg : kText;
  if (disabled) {
    text = kMuted;
    if (look == Look::Accent) fill = kBorder;
    edge = kBorder;
  }
  HPEN pen = CreatePen(PS_SOLID, 1, edge);
  HBRUSH br = CreateSolidBrush(fill);
  HGDIOBJ op = SelectObject(dc, pen);
  HGDIOBJ ob = SelectObject(dc, br);
  RoundRect(dc, r.left, r.top, r.right, r.bottom, 12, 12);
  SelectObject(dc, op);
  SelectObject(dc, ob);
  DeleteObject(pen);
  DeleteObject(br);
  SetBkMode(dc, TRANSPARENT);
  SelectObject(dc, res().font);
  SetTextColor(dc, text);
  RECT tr = r;
  if (arrow) {
    tr.left += 12;
    tr.right -= 30;
    DrawTextW(dc, label.c_str(), -1, &tr, DT_SINGLELINE | DT_VCENTER | DT_LEFT | DT_END_ELLIPSIS);
    int cx = r.right - 18, cy = (r.top + r.bottom) / 2;
    HPEN ap = CreatePen(PS_SOLID, 2, text);
    HGDIOBJ oa = SelectObject(dc, ap);
    MoveToEx(dc, cx - 5, cy - 2, nullptr);
    LineTo(dc, cx, cy + 3);
    LineTo(dc, cx + 5, cy - 2);
    SelectObject(dc, oa);
    DeleteObject(ap);
  } else {
    DrawTextW(dc, label.c_str(), -1, &tr, DT_SINGLELINE | DT_VCENTER | DT_CENTER);
  }
}

inline void paint_check(HDC dc, RECT r, const std::wstring& label, bool on, bool disabled) {
  FillRect(dc, &r, res().bg);
  int top = r.top + (r.bottom - r.top - 18) / 2;
  RECT box{r.left + 1, top, r.left + 19, top + 18};
  HPEN pen = CreatePen(PS_SOLID, 1, on ? kText : kBorder);
  HBRUSH br = CreateSolidBrush(on ? kText : kPanel);
  HGDIOBJ op = SelectObject(dc, pen);
  HGDIOBJ ob = SelectObject(dc, br);
  RoundRect(dc, box.left, box.top, box.right, box.bottom, 6, 6);
  if (on) {
    HPEN tick = CreatePen(PS_SOLID, 2, kBg);
    SelectObject(dc, tick);
    MoveToEx(dc, box.left + 4, box.top + 9, nullptr);
    LineTo(dc, box.left + 8, box.top + 13);
    LineTo(dc, box.left + 14, box.top + 5);
    SelectObject(dc, pen);
    DeleteObject(tick);
  }
  SelectObject(dc, op);
  SelectObject(dc, ob);
  DeleteObject(pen);
  DeleteObject(br);
  SetBkMode(dc, TRANSPARENT);
  SelectObject(dc, res().font);
  SetTextColor(dc, disabled ? kMuted : kText);
  RECT tr{r.left + 28, r.top, r.right, r.bottom};
  DrawTextW(dc, label.c_str(), -1, &tr, DT_SINGLELINE | DT_VCENTER | DT_LEFT);
}

inline void paint_radio(HDC dc, RECT r, const std::wstring& label, bool on, bool disabled) {
  FillRect(dc, &r, res().bg);
  int top = r.top + (r.bottom - r.top - 18) / 2;
  HPEN pen = CreatePen(PS_SOLID, 1, on ? kText : kBorder);
  HBRUSH br = CreateSolidBrush(kPanel);
  HGDIOBJ op = SelectObject(dc, pen);
  HGDIOBJ ob = SelectObject(dc, br);
  Ellipse(dc, r.left + 1, top, r.left + 19, top + 18);
  if (on) {
    HBRUSH dot = CreateSolidBrush(kText);
    HPEN none = CreatePen(PS_SOLID, 1, kText);
    SelectObject(dc, dot);
    SelectObject(dc, none);
    Ellipse(dc, r.left + 5, top + 4, r.left + 15, top + 14);
    SelectObject(dc, br);
    SelectObject(dc, pen);
    DeleteObject(dot);
    DeleteObject(none);
  }
  SelectObject(dc, op);
  SelectObject(dc, ob);
  DeleteObject(pen);
  DeleteObject(br);
  SetBkMode(dc, TRANSPARENT);
  SelectObject(dc, res().font);
  SetTextColor(dc, disabled ? kMuted : kText);
  RECT t{r.left + 28, r.top, r.right, r.bottom};
  DrawTextW(dc, label.c_str(), -1, &t, DT_SINGLELINE | DT_VCENTER | DT_LEFT);
}

struct PopupState {
  std::vector<std::wstring> items;
  int selected = -1;
  int hover = -1;
  int result = -1;
  bool done = false;
};

constexpr int kPopupItemH = 34;

inline LRESULT CALLBACK popup_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
  auto* s = reinterpret_cast<PopupState*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
  switch (msg) {
    case WM_CREATE:
      SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(reinterpret_cast<CREATESTRUCTW*>(lp)->lpCreateParams));
      return 0;
    case WM_PAINT: {
      PAINTSTRUCT ps;
      HDC dc = BeginPaint(hwnd, &ps);
      RECT c;
      GetClientRect(hwnd, &c);
      HPEN pen = CreatePen(PS_SOLID, 1, kBorder);
      HGDIOBJ op = SelectObject(dc, pen);
      HGDIOBJ ob = SelectObject(dc, res().bg);
      RoundRect(dc, c.left, c.top, c.right, c.bottom, 12, 12);
      SelectObject(dc, op);
      SelectObject(dc, ob);
      DeleteObject(pen);
      SetBkMode(dc, TRANSPARENT);
      SelectObject(dc, res().font);
      for (std::size_t i = 0; i < s->items.size(); ++i) {
        RECT it{c.left + 4, c.top + 4 + static_cast<int>(i) * kPopupItemH, c.right - 4, c.top + 4 + static_cast<int>(i + 1) * kPopupItemH};
        bool sel = static_cast<int>(i) == s->selected;
        bool hot = static_cast<int>(i) == s->hover;
        if (sel || hot) {
          HBRUSH b = CreateSolidBrush(sel ? RGB(50, 76, 86) : kHover);
          HGDIOBJ o2 = SelectObject(dc, b);
          HPEN np = static_cast<HPEN>(GetStockObject(NULL_PEN));
          HGDIOBJ o3 = SelectObject(dc, np);
          RoundRect(dc, it.left, it.top, it.right, it.bottom, 8, 8);
          SelectObject(dc, o2);
          SelectObject(dc, o3);
          DeleteObject(b);
        }
        SetTextColor(dc, kText);
        RECT tr{it.left + 10, it.top, it.right - 6, it.bottom};
        DrawTextW(dc, s->items[i].c_str(), -1, &tr, DT_SINGLELINE | DT_VCENTER | DT_LEFT);
      }
      EndPaint(hwnd, &ps);
      return 0;
    }
    case WM_MOUSEMOVE: {
      int idx = (static_cast<short>(HIWORD(lp)) - 4) / kPopupItemH;
      if (static_cast<short>(HIWORD(lp)) < 4 || idx >= static_cast<int>(s->items.size())) idx = -1;
      if (idx != s->hover) {
        s->hover = idx;
        InvalidateRect(hwnd, nullptr, FALSE);
      }
      return 0;
    }
    case WM_LBUTTONUP: {
      RECT c;
      GetClientRect(hwnd, &c);
      POINT p{static_cast<short>(LOWORD(lp)), static_cast<short>(HIWORD(lp))};
      if (PtInRect(&c, p) && s->hover >= 0) s->result = s->hover;
      s->done = true;
      return 0;
    }
    case WM_KEYDOWN:
      if (wp == VK_ESCAPE) s->done = true;
      return 0;
    case WM_KILLFOCUS:
    case WM_CAPTURECHANGED:
      s->done = true;
      return 0;
    case WM_ERASEBKGND:
      return 1;
  }
  return DefWindowProcW(hwnd, msg, wp, lp);
}

inline int popup_list(HWND owner, RECT anchor, const std::vector<std::wstring>& items, int selected) {
  init();
  static bool registered = false;
  HINSTANCE inst = GetModuleHandleW(nullptr);
  if (!registered) {
    WNDCLASSW wc{};
    wc.lpfnWndProc = popup_proc;
    wc.hInstance = inst;
    wc.hCursor = LoadCursorW(nullptr, MAKEINTRESOURCEW(32512));
    wc.lpszClassName = L"WoliumPopup";
    RegisterClassW(&wc);
    registered = true;
  }
  PopupState st;
  st.items = items;
  st.selected = selected;
  int h = static_cast<int>(items.size()) * kPopupItemH + 8;
  HWND w = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_TOPMOST, L"WoliumPopup", L"", WS_POPUP, anchor.left, anchor.bottom + 4,
                           anchor.right - anchor.left, h, owner, nullptr, inst, &st);
  ShowWindow(w, SW_SHOWNOACTIVATE);
  SetForegroundWindow(w);
  SetFocus(w);
  SetCapture(w);
  MSG m;
  while (!st.done && GetMessageW(&m, nullptr, 0, 0) > 0) {
    if (m.message == WM_LBUTTONDOWN && m.hwnd != w) {
      st.done = true;
      break;
    }
    TranslateMessage(&m);
    DispatchMessageW(&m);
  }
  ReleaseCapture();
  DestroyWindow(w);
  return st.result;
}

struct DialogState {
  std::wstring text;
  std::vector<std::wstring> labels;
  int accent = -1;
  int result = -1;
  bool done = false;
  RECT text_rect{};
};

constexpr int kDlgButtonBase = 500;

inline LRESULT CALLBACK dialog_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
  auto* s = reinterpret_cast<DialogState*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
  switch (msg) {
    case WM_CREATE:
      SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(reinterpret_cast<CREATESTRUCTW*>(lp)->lpCreateParams));
      return 0;
    case WM_ERASEBKGND: {
      RECT r;
      GetClientRect(hwnd, &r);
      FillRect(reinterpret_cast<HDC>(wp), &r, res().bg);
      return 1;
    }
    case WM_PAINT: {
      PAINTSTRUCT ps;
      HDC dc = BeginPaint(hwnd, &ps);
      SetBkMode(dc, TRANSPARENT);
      SelectObject(dc, res().font);
      SetTextColor(dc, kText);
      DrawTextW(dc, s->text.c_str(), -1, &s->text_rect, DT_WORDBREAK | DT_LEFT);
      EndPaint(hwnd, &ps);
      return 0;
    }
    case WM_DRAWITEM: {
      auto* d = reinterpret_cast<const DRAWITEMSTRUCT*>(lp);
      int idx = static_cast<int>(d->CtlID) - kDlgButtonBase;
      wchar_t buf[256];
      GetWindowTextW(d->hwndItem, buf, 256);
      POINT p;
      GetCursorPos(&p);
      RECT wr;
      GetWindowRect(d->hwndItem, &wr);
      bool hover = PtInRect(&wr, p) != 0;
      paint_button(d->hDC, d->rcItem, buf, idx == s->accent ? Look::Accent : Look::Normal, false, (d->itemState & ODS_SELECTED) != 0, false, hover);
      return TRUE;
    }
    case WM_COMMAND: {
      int id = LOWORD(wp) - kDlgButtonBase;
      if (id >= 0 && id < static_cast<int>(s->labels.size())) {
        s->result = id;
        s->done = true;
      }
      return 0;
    }
    case WM_CLOSE:
      s->done = true;
      return 0;
  }
  return DefWindowProcW(hwnd, msg, wp, lp);
}

inline int dialog(const std::wstring& title, const std::wstring& text, const std::vector<std::wstring>& labels, int accent) {
  init();
  static bool registered = false;
  HINSTANCE inst = GetModuleHandleW(nullptr);
  if (!registered) {
    WNDCLASSW wc{};
    wc.lpfnWndProc = dialog_proc;
    wc.hInstance = inst;
    wc.hCursor = LoadCursorW(nullptr, MAKEINTRESOURCEW(32512));
    wc.hIcon = LoadIconW(inst, MAKEINTRESOURCEW(1));
    wc.lpszClassName = L"WoliumDialog";
    RegisterClassW(&wc);
    registered = true;
  }
  const int width = 460, pad = 24;
  DialogState st;
  st.text = text;
  st.labels = labels;
  st.accent = accent;

  HDC dc = GetDC(nullptr);
  HGDIOBJ of = SelectObject(dc, res().font);
  RECT calc{0, 0, width - pad * 2, 0};
  DrawTextW(dc, text.c_str(), -1, &calc, DT_WORDBREAK | DT_CALCRECT);
  std::vector<int> widths;
  for (const auto& l : labels) {
    RECT tr{0, 0, 0, 0};
    DrawTextW(dc, l.c_str(), -1, &tr, DT_SINGLELINE | DT_CALCRECT);
    widths.push_back(std::max<int>(96, tr.right - tr.left + 36));
  }
  SelectObject(dc, of);
  ReleaseDC(nullptr, dc);

  int text_h = calc.bottom - calc.top;
  st.text_rect = RECT{pad, pad, width - pad, pad + text_h};
  int client_h = pad + text_h + pad + 38 + pad;
  RECT wr{0, 0, width, client_h};
  AdjustWindowRect(&wr, WS_CAPTION | WS_SYSMENU, FALSE);
  int sw = GetSystemMetrics(SM_CXSCREEN), sh = GetSystemMetrics(SM_CYSCREEN);
  int ww = wr.right - wr.left, wh = wr.bottom - wr.top;
  HWND w = CreateWindowExW(WS_EX_TOPMOST, L"WoliumDialog", title.c_str(), WS_CAPTION | WS_SYSMENU, (sw - ww) / 2, (sh - wh) / 2, ww, wh,
                           nullptr, nullptr, inst, &st);
  dark_title(w);
  int x = width - pad;
  for (int i = static_cast<int>(labels.size()) - 1; i >= 0; --i) {
    x -= widths[static_cast<std::size_t>(i)];
    HWND b = CreateWindowExW(0, L"BUTTON", labels[static_cast<std::size_t>(i)].c_str(), WS_CHILD | WS_VISIBLE | BS_OWNERDRAW | WS_TABSTOP, x,
                             pad + text_h + pad, widths[static_cast<std::size_t>(i)], 38, w,
                             reinterpret_cast<HMENU>(static_cast<INT_PTR>(kDlgButtonBase + i)), inst, nullptr);
    SendMessageW(b, WM_SETFONT, reinterpret_cast<WPARAM>(res().font), TRUE);
    x -= 10;
  }
  ShowWindow(w, SW_SHOW);
  SetForegroundWindow(w);
  MSG m;
  while (!st.done && GetMessageW(&m, nullptr, 0, 0) > 0) {
    if (!IsDialogMessageW(w, &m)) {
      TranslateMessage(&m);
      DispatchMessageW(&m);
    }
  }
  DestroyWindow(w);
  return st.result;
}

}
