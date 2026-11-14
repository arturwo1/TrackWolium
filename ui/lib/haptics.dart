import 'dart:io';
import 'package:flutter/services.dart';
import 'data.dart';

const _channel = MethodChannel('wolium/usage');
const _table = [
  [[10, 50], [15, 80], [25, 130]],
  [[12, 100], [20, 150], [30, 200]],
  [[15, 170], [25, 220], [40, 255]],
];

int hapticLevel = 1;

File _file() => File('${dataDir()}${Platform.pathSeparator}haptics');

void loadHaptics() {
  if (!Platform.isAndroid) return;
  try {
    final f = _file();
    if (f.existsSync()) hapticLevel = (int.tryParse(f.readAsStringSync().trim()) ?? 1).clamp(0, 3);
  } catch (_) {}
}

void saveHaptics(int level) {
  hapticLevel = level;
  try {
    Directory(dataDir()).createSync(recursive: true);
    _file().writeAsStringSync('$level');
  } catch (_) {}
}

void buzz([int power = 0]) {
  if (!Platform.isAndroid || hapticLevel == 0) return;
  final t = _table[hapticLevel - 1][power.clamp(0, 2)];
  _channel.invokeMethod<void>('vibrate', {'ms': t[0], 'amp': t[1]}).catchError((_) {});
}
