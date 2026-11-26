import 'dart:async';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'data.dart';
import 'win.dart';

class WindowState with WidgetsBindingObserver {
  WindowState._();

  static final WindowState instance = WindowState._();

  Timer? _timer;
  String _last = '';
  bool _wantMaximize = false;
  DateTime? _suppressSaveUntil;

  File get _file => File('${dataDir()}${Platform.pathSeparator}window');

  void restore() {
    if (!Platform.isWindows) return;
    try {
      final parts = _file.readAsStringSync().trim().split(' ').map(int.parse).toList();
      if (parts.length < 5) return;
      final box = WindowBox(parts[0], parts[1], parts[2], parts[3], parts[4] == 1);
      if (!boxVisible(box)) return;
      _wantMaximize = box.maximized;
      if (box.maximized) {
        _suppressSaveUntil = DateTime.now().add(const Duration(seconds: 3));
      }
      applyWindowBox(box);
      _last = _encode(box);
    } catch (_) {}
  }

  void attach() {
    if (!Platform.isWindows) return;
    WidgetsBinding.instance.addObserver(this);
    Timer.periodic(const Duration(seconds: 2), (_) => save());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_wantMaximize) maximizeMainWindow();
    });
  }

  String _encode(WindowBox b) => '${b.left} ${b.top} ${b.right} ${b.bottom} ${b.maximized ? 1 : 0}';

  @override
  void didChangeMetrics() {
    if (_suppressSaveUntil != null && DateTime.now().isBefore(_suppressSaveUntil!)) return;
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 800), save);
  }

  void save() {
    if (_suppressSaveUntil != null && DateTime.now().isBefore(_suppressSaveUntil!)) return;
    final box = readWindowBox();
    if (box == null) return;
    final text = _encode(box);
    if (text == _last) return;
    _last = text;
    try {
      Directory(dataDir()).createSync(recursive: true);
      _file.writeAsStringSync(text);
    } catch (_) {}
  }
}
