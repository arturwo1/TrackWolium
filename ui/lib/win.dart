import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';

const _fileMapRead = 4;
const _eventModify = 2;
const _synchronize = 0x00100000;
const _swRestore = 9;

final DynamicLibrary? _k32 = Platform.isWindows ? DynamicLibrary.open('kernel32.dll') : null;
final DynamicLibrary? _u32 = Platform.isWindows ? DynamicLibrary.open('user32.dll') : null;

final _openMapping = _k32?.lookupFunction<IntPtr Function(Uint32, Int32, Pointer<Utf16>), int Function(int, int, Pointer<Utf16>)>('OpenFileMappingW');
final _mapView = _k32?.lookupFunction<Pointer<Void> Function(IntPtr, Uint32, Uint32, Uint32, IntPtr), Pointer<Void> Function(int, int, int, int, int)>('MapViewOfFile');
final _unmapView = _k32?.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>('UnmapViewOfFile');
final _closeHandle = _k32?.lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');
final _tick = _k32?.lookupFunction<Uint64 Function(), int Function()>('GetTickCount64');
final _openEvent = _k32?.lookupFunction<IntPtr Function(Uint32, Int32, Pointer<Utf16>), int Function(int, int, Pointer<Utf16>)>('OpenEventW');
final _setEvent = _k32?.lookupFunction<Int32 Function(IntPtr), int Function(int)>('SetEvent');
final _openMutex = _k32?.lookupFunction<IntPtr Function(Uint32, Int32, Pointer<Utf16>), int Function(int, int, Pointer<Utf16>)>('OpenMutexW');
final _createMutex = _k32?.lookupFunction<IntPtr Function(Pointer<Void>, Int32, Pointer<Utf16>), int Function(Pointer<Void>, int, Pointer<Utf16>)>('CreateMutexW');
final _findWindow = _u32?.lookupFunction<IntPtr Function(Pointer<Utf16>, Pointer<Utf16>), int Function(Pointer<Utf16>, Pointer<Utf16>)>('FindWindowW');
final _showWindow = _u32?.lookupFunction<Int32 Function(IntPtr, Int32), int Function(int, int)>('ShowWindow');
final _setForeground = _u32?.lookupFunction<Int32 Function(IntPtr), int Function(int)>('SetForegroundWindow');

int? heartbeatAgeMs() {
  if (_openMapping == null) return null;
  final name = r'Local\TrackWolium.Heartbeat'.toNativeUtf16();
  try {
    final map = _openMapping!(_fileMapRead, 0, name);
    if (map == 0) return null;
    try {
      final view = _mapView!(map, _fileMapRead, 0, 0, 8);
      if (view == nullptr) return null;
      final value = view.cast<Int64>().value;
      _unmapView!(view);
      if (value == 0) return null;
      return _tick!() - value;
    } finally {
      _closeHandle!(map);
    }
  } finally {
    calloc.free(name);
  }
}

void requestFlush() {
  if (_openEvent == null) return;
  final name = r'Local\TrackWolium.CoreFlush'.toNativeUtf16();
  try {
    final ev = _openEvent!(_eventModify, 0, name);
    if (ev == 0) return;
    _setEvent!(ev);
    _closeHandle!(ev);
  } finally {
    calloc.free(name);
  }
}

bool claimSingleInstance() {
  if (_openMutex == null) return true;
  final name = r'Local\Wolium.Ui'.toNativeUtf16();
  try {
    final existing = _openMutex!(_synchronize, 0, name);
    if (existing != 0) {
      _closeHandle!(existing);
      focusExistingWindow();
      return false;
    }
    _createMutex!(nullptr, 0, name);
    return true;
  } finally {
    calloc.free(name);
  }
}

void focusExistingWindow() {
  if (_findWindow == null) return;
  final title = 'Wolium'.toNativeUtf16();
  final cls = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
  try {
    final hwnd = _findWindow!(cls, title);
    if (hwnd == 0) return;
    _showWindow!(hwnd, _swRestore);
    _setForeground!(hwnd);
  } finally {
    calloc.free(title);
    calloc.free(cls);
  }
}

String? readLive() {
  if (_openMapping == null) return null;
  final name = r'Local\TrackWolium.Live'.toNativeUtf16();
  try {
    final map = _openMapping!(_fileMapRead, 0, name);
    if (map == 0) return null;
    try {
      final view = _mapView!(map, _fileMapRead, 0, 0, 0);
      if (view == nullptr) return null;
      try {
        final len = view.cast<Int32>().value;
        if (len <= 0 || len > 256 * 1024 - 8) return null;
        final bytes = Uint8List.fromList(view.cast<Uint8>().elementAt(8).asTypedList(len));
        if (view.cast<Int32>().value != len) return null;
        return utf8.decode(bytes, allowMalformed: true);
      } finally {
        _unmapView!(view);
      }
    } finally {
      _closeHandle!(map);
    }
  } finally {
    calloc.free(name);
  }
}

final _getPlacement = _u32?.lookupFunction<Int32 Function(IntPtr, Pointer<Int32>), int Function(int, Pointer<Int32>)>('GetWindowPlacement');
final _setPlacement = _u32?.lookupFunction<Int32 Function(IntPtr, Pointer<Int32>), int Function(int, Pointer<Int32>)>('SetWindowPlacement');
final _monitorFromRect = _u32?.lookupFunction<IntPtr Function(Pointer<Int32>, Uint32), int Function(Pointer<Int32>, int)>('MonitorFromRect');

int _mainWindow() {
  if (_findWindow == null) return 0;
  final cls = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
  try {
    return _findWindow!(cls, Pointer<Utf16>.fromAddress(0));
  } finally {
    calloc.free(cls);
  }
}

class WindowBox {
  const WindowBox(this.left, this.top, this.right, this.bottom, this.maximized);

  final int left;
  final int top;
  final int right;
  final int bottom;
  final bool maximized;
}

WindowBox? readWindowBox() {
  final h = _mainWindow();
  if (h == 0 || _getPlacement == null) return null;
  final p = calloc<Int32>(11);
  try {
    p[0] = 44;
    if (_getPlacement!(h, p) == 0) return null;
    final show = p[2];
    if (show == 2) return null;
    return WindowBox(p[7], p[8], p[9], p[10], show == 3);
  } finally {
    calloc.free(p);
  }
}

bool boxVisible(WindowBox b) {
  if (_monitorFromRect == null) return true;
  if (b.right - b.left < 300 || b.bottom - b.top < 240) return false;
  final r = calloc<Int32>(4);
  try {
    r[0] = b.left;
    r[1] = b.top;
    r[2] = b.right;
    r[3] = b.top + 48;
    return _monitorFromRect!(r, 0) != 0;
  } finally {
    calloc.free(r);
  }
}

void applyWindowBox(WindowBox b) {
  final h = _mainWindow();
  if (h == 0 || _getPlacement == null || _setPlacement == null) return;
  final p = calloc<Int32>(11);
  try {
    p[0] = 44;
    if (_getPlacement!(h, p) == 0) return;
    p[7] = b.left;
    p[8] = b.top;
    p[9] = b.right;
    p[10] = b.bottom;
    _setPlacement!(h, p);
  } finally {
    calloc.free(p);
  }
}

void maximizeMainWindow() {
  final h = _mainWindow();
  if (h != 0) _showWindow?.call(h, 3);
}
