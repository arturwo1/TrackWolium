import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

const _swRestore = 9;
const _gwOwner = 4;
const _gwlExStyle = -20;
const _wsExToolWindow = 0x80;
const _wsExAppWindow = 0x40000;
const _processTerminate = 0x0001;
const _processQueryLimited = 0x1000;

typedef _EnumNative = Int32 Function(IntPtr hwnd, IntPtr lparam);

final DynamicLibrary? _k32 = Platform.isWindows ? DynamicLibrary.open('kernel32.dll') : null;
final DynamicLibrary? _u32 = Platform.isWindows ? DynamicLibrary.open('user32.dll') : null;

final _enumWindows = _u32?.lookupFunction<Int32 Function(Pointer<NativeFunction<_EnumNative>>, IntPtr), int Function(Pointer<NativeFunction<_EnumNative>>, int)>('EnumWindows');
final _getWindowThreadProcessId = _u32?.lookupFunction<Uint32 Function(IntPtr, Pointer<Uint32>), int Function(int, Pointer<Uint32>)>('GetWindowThreadProcessId');
final _isWindowVisible = _u32?.lookupFunction<Int32 Function(IntPtr), int Function(int)>('IsWindowVisible');
final _isIconic = _u32?.lookupFunction<Int32 Function(IntPtr), int Function(int)>('IsIconic');
final _getWindow = _u32?.lookupFunction<IntPtr Function(IntPtr, Uint32), int Function(int, int)>('GetWindow');
final _getWindowLong = _u32?.lookupFunction<Int32 Function(IntPtr, Int32), int Function(int, int)>('GetWindowLongW');
final _getTextLength = _u32?.lookupFunction<Int32 Function(IntPtr), int Function(int)>('GetWindowTextLengthW');
final _showWindow = _u32?.lookupFunction<Int32 Function(IntPtr, Int32), int Function(int, int)>('ShowWindow');
final _setForeground = _u32?.lookupFunction<Int32 Function(IntPtr), int Function(int)>('SetForegroundWindow');
final _bringToTop = _u32?.lookupFunction<Int32 Function(IntPtr), int Function(int)>('BringWindowToTop');
final _getForeground = _u32?.lookupFunction<IntPtr Function(), int Function()>('GetForegroundWindow');
final _attachInput = _u32?.lookupFunction<Int32 Function(Uint32, Uint32, Int32), int Function(int, int, int)>('AttachThreadInput');
final _currentThread = _k32?.lookupFunction<Uint32 Function(), int Function()>('GetCurrentThreadId');
final _openProcess = _k32?.lookupFunction<IntPtr Function(Uint32, Int32, Uint32), int Function(int, int, int)>('OpenProcess');
final _closeHandle = _k32?.lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');
final _queryImage = _k32?.lookupFunction<Int32 Function(IntPtr, Uint32, Pointer<Utf16>, Pointer<Uint32>), int Function(int, int, Pointer<Utf16>, Pointer<Uint32>)>('QueryFullProcessImageNameW');
final _terminate = _k32?.lookupFunction<Int32 Function(IntPtr, Uint32), int Function(int, int)>('TerminateProcess');
final _enumProcesses = _k32?.lookupFunction<Int32 Function(Pointer<Uint32>, Uint32, Pointer<Uint32>), int Function(Pointer<Uint32>, int, Pointer<Uint32>)>('K32EnumProcesses');

final int _self = pid;
String _wantedApp = '';
int _foundWindow = 0;
final Map<int, String> _pidNames = {};

String _imageName(int pid, {int access = _processQueryLimited}) {
  final cached = _pidNames[pid];
  if (cached != null) return cached;
  var name = '';
  final h = _openProcess!(access, 0, pid);
  if (h != 0) {
    final buf = calloc<Uint16>(1024).cast<Utf16>();
    final len = calloc<Uint32>()..value = 1024;
    try {
      if (_queryImage!(h, 0, buf, len) != 0) {
        final full = buf.toDartString(length: len.value);
        final i = full.lastIndexOf(RegExp(r'[\\/]'));
        name = (i < 0 ? full : full.substring(i + 1)).toLowerCase();
      }
    } finally {
      calloc.free(buf);
      calloc.free(len);
      _closeHandle!(h);
    }
  }
  _pidNames[pid] = name;
  return name;
}

int _onWindow(int hwnd, int lparam) {
  if (_isWindowVisible!(hwnd) == 0) return 1;
  if (_getWindow!(hwnd, _gwOwner) != 0) return 1;
  final ex = _getWindowLong!(hwnd, _gwlExStyle);
  if ((ex & _wsExToolWindow) != 0 && (ex & _wsExAppWindow) == 0) return 1;
  if (_getTextLength!(hwnd) == 0) return 1;
  final pidPtr = calloc<Uint32>();
  try {
    _getWindowThreadProcessId!(hwnd, pidPtr);
    if (_imageName(pidPtr.value) == _wantedApp) {
      _foundWindow = hwnd;
      return 0;
    }
  } finally {
    calloc.free(pidPtr);
  }
  return 1;
}

int _findWindow(String app) {
  if (_enumWindows == null || _openProcess == null) return 0;
  _wantedApp = app.toLowerCase();
  _foundWindow = 0;
  _pidNames.clear();
  final cb = Pointer.fromFunction<_EnumNative>(_onWindow, 1);
  _enumWindows!(cb, 0);
  _pidNames.clear();
  return _foundWindow;
}

bool _focusWindows(String app) {
  final hwnd = _findWindow(app);
  if (hwnd == 0) return false;
  if (_isIconic!(hwnd) != 0) _showWindow!(hwnd, _swRestore);
  final fg = _getForeground!();
  final me = _currentThread!();
  final pidPtr = calloc<Uint32>();
  var fgThread = 0;
  try {
    if (fg != 0) fgThread = _getWindowThreadProcessId!(fg, pidPtr);
  } finally {
    calloc.free(pidPtr);
  }
  final attach = fgThread != 0 && fgThread != me;
  if (attach) _attachInput!(me, fgThread, 1);
  _bringToTop!(hwnd);
  final ok = _setForeground!(hwnd) != 0;
  if (attach) _attachInput!(me, fgThread, 0);
  return ok;
}

bool _runningWindows(String app) {
  if (_enumProcesses == null || _openProcess == null) return false;
  final want = app.toLowerCase();
  const cap = 4096;
  final pids = calloc<Uint32>(cap);
  final needed = calloc<Uint32>();
  try {
    if (_enumProcesses!(pids, cap * 4, needed) == 0) return false;
    final count = needed.value ~/ 4;
    _pidNames.clear();
    for (var i = 0; i < count; i++) {
      final pid = pids[i];
      if (pid == 0 || pid == 4) continue;
      if (_imageName(pid) == want) return true;
    }
    return false;
  } finally {
    _pidNames.clear();
    calloc.free(pids);
    calloc.free(needed);
  }
}

int _terminateWindows(String app) {
  if (_enumProcesses == null || _openProcess == null) return 0;
  final want = app.toLowerCase();
  const cap = 4096;
  final pids = calloc<Uint32>(cap);
  final needed = calloc<Uint32>();
  var killed = 0;
  try {
    if (_enumProcesses!(pids, cap * 4, needed) == 0) return 0;
    final count = needed.value ~/ 4;
    _pidNames.clear();
    for (var i = 0; i < count; i++) {
      final pid = pids[i];
      if (pid == 0 || pid == 4 || pid == _self) continue;
      if (_imageName(pid) != want) continue;
      final h = _openProcess!(_processTerminate, 0, pid);
      if (h == 0) continue;
      if (_terminate!(h, 1) != 0) killed++;
      _closeHandle!(h);
    }
  } finally {
    _pidNames.clear();
    calloc.free(pids);
    calloc.free(needed);
  }
  return killed;
}

String _procName(String dir) {
  try {
    final exe = Link('$dir/exe').targetSync();
    var name = exe.split('/').last;
    if (name.endsWith(' (deleted)')) name = name.substring(0, name.length - 10);
    return name;
  } catch (_) {
    try {
      return File('$dir/comm').readAsStringSync().trim();
    } catch (_) {
      return '';
    }
  }
}

List<int> _linuxPids(String app) {
  final out = <int>[];
  try {
    for (final e in Directory('/proc').listSync(followLinks: false)) {
      final id = e.path.split('/').last;
      final pid = int.tryParse(id);
      if (pid == null || pid == _self) continue;
      if (_procName(e.path) == app) out.add(pid);
    }
  } catch (_) {}
  return out;
}

Future<List<int>> _macPids(String app) async {
  try {
    final r = await Process.run('pgrep', ['-x', app]);
    if (r.exitCode != 0) return [];
    return [for (final l in (r.stdout as String).split('\n')) if (int.tryParse(l.trim()) != null) int.parse(l.trim())].where((p) => p != _self).toList();
  } catch (_) {
    return [];
  }
}

Future<bool> _focusLinux(String app) async {
  final pids = _linuxPids(app);
  if (pids.isEmpty) return false;
  try {
    final r = await Process.run('wmctrl', ['-lp']);
    if (r.exitCode == 0) {
      for (final line in (r.stdout as String).split('\n')) {
        final p = line.trim().split(RegExp(r'\s+'));
        if (p.length < 3) continue;
        final pid = int.tryParse(p[2]);
        if (pid != null && pids.contains(pid)) {
          final a = await Process.run('wmctrl', ['-ia', p[0]]);
          if (a.exitCode == 0) return true;
        }
      }
    }
  } catch (_) {}
  for (final pid in pids) {
    try {
      final s = await Process.run('xdotool', ['search', '--onlyvisible', '--pid', '$pid']);
      if (s.exitCode != 0) continue;
      for (final id in (s.stdout as String).split('\n')) {
        if (id.trim().isEmpty) continue;
        final a = await Process.run('xdotool', ['windowactivate', id.trim()]);
        if (a.exitCode == 0) return true;
      }
    } catch (_) {}
  }
  return false;
}

Future<bool> _focusMac(String app) async {
  try {
    final script = 'tell application "System Events" to set frontmost of first process whose name is "${app.replaceAll('"', '')}" to true';
    final r = await Process.run('osascript', ['-e', script]);
    return r.exitCode == 0;
  } catch (_) {
    return false;
  }
}

class AppLive {
  const AppLive(this.running, this.window);

  final bool running;
  final bool window;
}

Future<AppLive> appLive(String app) async {
  if (Platform.isWindows) {
    final running = _runningWindows(app);
    return AppLive(running, running && _findWindow(app) != 0);
  }
  final pids = Platform.isLinux ? _linuxPids(app) : (Platform.isMacOS ? await _macPids(app) : <int>[]);
  return AppLive(pids.isNotEmpty, pids.isNotEmpty);
}

bool get appControlSupported => Platform.isWindows || Platform.isLinux || Platform.isMacOS;

Future<bool> focusApp(String app) async {
  if (Platform.isWindows) return _focusWindows(app);
  if (Platform.isLinux) return _focusLinux(app);
  if (Platform.isMacOS) return _focusMac(app);
  return false;
}

Future<int> endApp(String app) async {
  if (Platform.isWindows) return _terminateWindows(app);
  final pids = Platform.isLinux ? _linuxPids(app) : (Platform.isMacOS ? await _macPids(app) : <int>[]);
  var killed = 0;
  for (final pid in pids) {
    if (Process.killPid(pid)) killed++;
  }
  return killed;
}
