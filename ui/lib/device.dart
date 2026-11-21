import 'dart:io';
import 'dart:math';
import 'package:flutter/services.dart';
import 'data.dart';

String _file(String name) => '${dataDir()}${Platform.pathSeparator}$name';

String _newId() {
  final r = Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

String deviceId() {
  final f = File(_file('device_id'));
  try {
    final text = f.existsSync() ? f.readAsStringSync().trim() : '';
    if (RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$').hasMatch(text)) return text;
    final id = _newId();
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(id);
    return id;
  } catch (_) {
    return '';
  }
}

String _defaultName = '';

Future<void> loadDefaultDeviceName() async {
  if (Platform.isAndroid) {
    try {
      _defaultName = (await const MethodChannel('wolium/usage').invokeMethod<String>('deviceName') ?? '').trim();
    } catch (_) {}
    return;
  }
  if (Platform.isWindows) {
    final host = Platform.localHostname.trim();
    if (host.isNotEmpty && host.toLowerCase() != 'localhost') {
      _defaultName = host;
      return;
    }
    _defaultName = (Platform.environment['COMPUTERNAME'] ?? '').trim();
    return;
  }
  _defaultName = Platform.localHostname.trim();
}

String defaultDeviceName() => _defaultName.isEmpty ? Platform.operatingSystem : _defaultName;

String deviceName() {
  try {
    final f = File(_file('device_name'));
    final text = f.existsSync() ? f.readAsStringSync().trim() : '';
    if (text.isNotEmpty) return text;
  } catch (_) {}
  return defaultDeviceName();
}

void saveDeviceName(String name) {
  final value = name.trim();
  final f = File(_file('device_name'));
  try {
    if (value.isEmpty || value == defaultDeviceName()) {
      if (f.existsSync()) f.deleteSync();
      return;
    }
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(value.length > 64 ? value.substring(0, 64) : value);
  } catch (_) {}
}
