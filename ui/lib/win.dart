import 'dart:ffi';
import 'dart:io';
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
