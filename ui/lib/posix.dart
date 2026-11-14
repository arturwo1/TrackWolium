import 'dart:ffi';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:ffi/ffi.dart';
import 'data.dart';

String homeTag() {
  final home = Platform.environment['HOME'] ?? '';
  final i = home.lastIndexOf('/');
  final tag = i < 0 ? home : home.substring(i + 1);
  return tag.isEmpty ? 'user' : tag;
}

String runtimeDir() {
  if (Platform.isMacOS) return '/tmp/wolium-${homeTag()}';
  final x = Platform.environment['XDG_RUNTIME_DIR'];
  if (x != null && x.isNotEmpty) return '$x/wolium';
  final user = Platform.environment['USER'] ?? Platform.environment['LOGNAME'] ?? 'user';
  return '/tmp/wolium-$user';
}

final DynamicLibrary? _libc = Platform.isLinux || Platform.isMacOS ? DynamicLibrary.process() : null;
final _open = _libc?.lookupFunction<Int32 Function(Pointer<Utf8>, Int32, Int32), int Function(Pointer<Utf8>, int, int)>('open');
final _flock = _libc?.lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>('flock');

int? posixHeartbeatAgeMs() {
  try {
    final f = File('${runtimeDir()}/live');
    if (!f.existsSync()) return null;
    return DateTime.now().difference(f.lastModifiedSync()).inMilliseconds;
  } catch (_) {
    return null;
  }
}

String? posixReadLive() {
  try {
    final f = File('${runtimeDir()}/live');
    return f.existsSync() ? f.readAsStringSync() : null;
  } catch (_) {
    return null;
  }
}

void posixRequestFlush() {
  try {
    final dir = Directory(runtimeDir());
    if (!dir.existsSync()) return;
    File('${dir.path}/flush').writeAsStringSync('1');
  } catch (_) {}
}

bool posixClaimSingleInstance() {
  if (_open == null || _flock == null) return true;
  try {
    final dir = Directory(runtimeDir());
    dir.createSync(recursive: true);
    final path = '${dir.path}/ui.lock'.toNativeUtf8();
    final fd = _open!(path, Platform.isMacOS ? 0x202 : 0x42, 0x180);
    calloc.free(path);
    if (fd < 0) return true;
    return _flock!(fd, 6) == 0;
  } catch (_) {
    return true;
  }
}

void posixTouchAlive() {
  try {
    final dir = Directory(runtimeDir());
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final f = File('${dir.path}/ui.alive');
    if (f.existsSync()) {
      f.setLastModifiedSync(DateTime.now());
    } else {
      f.writeAsStringSync('1');
    }
  } catch (_) {}
}

String autostartFile() {
  final home = Platform.environment['HOME'] ?? '';
  if (Platform.isMacOS) return '$home/Library/LaunchAgents/io.github.arturwo1.wolium.plist';
  final cfg = Platform.environment['XDG_CONFIG_HOME'] ?? '$home/.config';
  return '$cfg/autostart/wolium.desktop';
}

bool posixAutostartEnabled() => File(autostartFile()).existsSync();

void posixSetAutostart(bool on) {
  final f = File(autostartFile());
  try {
    if (on) {
      f.parent.createSync(recursive: true);
      final exe = '${installDir()}/trackwolium-core';
      if (Platform.isMacOS) {
        f.writeAsStringSync('<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n<key>Label</key><string>io.github.arturwo1.wolium</string>\n<key>ProgramArguments</key><array><string>$exe</string></array>\n<key>RunAtLoad</key><true/>\n<key>ProcessType</key><string>Background</string>\n</dict>\n</plist>\n');
        return;
      }
      f.writeAsStringSync('[Desktop Entry]\nType=Application\nName=Wolium\nExec="$exe"\nX-GNOME-Autostart-enabled=true\nTerminal=false\n');
    } else if (f.existsSync()) {
      f.deleteSync();
    }
  } catch (_) {}
}

Future<void> posixStartService() async {
  final exe = '${installDir()}/trackwolium-core';
  if (!File(exe).existsSync()) return;
  try {
    await Process.start(exe, const [], mode: ProcessStartMode.detached);
  } catch (_) {}
}

Future<void> openPath(String path, {bool select = false}) async {
  try {
    if (path.startsWith('content://')) {
      await const MethodChannel('wolium/usage').invokeMethod('openUri', {'uri': path});
    } else if (Platform.isWindows) {
      await Process.run('explorer', select ? ['/select,', path] : [path]);
    } else if (Platform.isMacOS) {
      await Process.run('open', select ? ['-R', path] : [path]);
    } else if (Platform.isLinux) {
      final target = select ? File(path).parent.path : path;
      await Process.run('xdg-open', [target]);
    }
  } catch (_) {}
}
