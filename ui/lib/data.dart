import 'dart:convert';
import 'dart:io';
import 'package:sqlite3/sqlite3.dart';

class AppUsage {
  AppUsage(this.app);

  final String app;
  final List<int> ms = [0, 0, 0, 0];

  int get visible => ms[0] + ms[1] + ms[2];
  int get total => visible + ms[3];
}

String installDir() => File(Platform.resolvedExecutable).parent.path;

String dataDir() => '${installDir()}${Platform.pathSeparator}userdata';

String dbPath() => '${dataDir()}${Platform.pathSeparator}usage.db';

String formatMs(int ms) {
  final s = ms ~/ 1000;
  if (s < 60) return '${s}s';
  final m = s ~/ 60;
  if (m < 60) return '${m}m ${s % 60}s';
  final h = m ~/ 60;
  return '${h}h ${m % 60}m';
}

class Usage {
  Database? _db;

  bool get available => File(dbPath()).existsSync();

  Database? _open() {
    if (_db != null) return _db;
    if (!available) return null;
    try {
      _db = sqlite3.open(dbPath(), mode: OpenMode.readOnly);
    } catch (_) {
      _db = null;
    }
    return _db;
  }

  List<String> days() {
    final db = _open();
    if (db == null) return [];
    try {
      return db
          .select('SELECT DISTINCT day FROM usage ORDER BY day DESC LIMIT 60')
          .map((r) => r['day'] as String)
          .toList();
    } catch (_) {
      return [];
    }
  }

  List<AppUsage> day(String day) {
    final db = _open();
    if (db == null) return [];
    final map = <String, AppUsage>{};
    try {
      for (final r in db.select('SELECT app, state, ms FROM usage WHERE day = ?', [day])) {
        final state = r['state'] as int;
        if (state < 0 || state > 3) continue;
        map.putIfAbsent(r['app'] as String, () => AppUsage(r['app'] as String)).ms[state] += r['ms'] as int;
      }
    } catch (_) {
      return [];
    }
    final list = map.values.where((a) => a.visible > 0).toList();
    list.sort((a, b) {
      final c = b.visible.compareTo(a.visible);
      return c != 0 ? c : b.total.compareTo(a.total);
    });
    return list;
  }

  Duration? sinceLastWrite() {
    final candidates = [dbPath(), '${dbPath()}-wal'];
    DateTime? newest;
    for (final p in candidates) {
      final f = File(p);
      if (!f.existsSync()) continue;
      final t = f.lastModifiedSync();
      if (newest == null || t.isAfter(newest)) newest = t;
    }
    return newest == null ? null : DateTime.now().difference(newest);
  }

  void close() {
    _db?.dispose();
    _db = null;
  }
}

class Settings {
  Settings._(this._file, this._map);

  final File _file;
  final Map<String, dynamic> _map;

  static Settings load() {
    final f = File('${dataDir()}${Platform.pathSeparator}ui.json');
    Map<String, dynamic> m = {};
    try {
      if (f.existsSync()) m = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    } catch (_) {}
    return Settings._(f, m);
  }

  bool get accepted => _map['accepted'] == true;

  set accepted(bool v) {
    _map['accepted'] = v;
    _save();
  }

  void _save() {
    try {
      _file.parent.createSync(recursive: true);
      _file.writeAsStringSync(jsonEncode(_map));
    } catch (_) {}
  }
}

const _runKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';

Future<bool> autostartEnabled() async {
  final r = await Process.run('reg', ['query', _runKey, '/v', 'Wolium']);
  return r.exitCode == 0;
}

Future<void> setAutostart(bool on) async {
  if (on) {
    await Process.run('reg', [
      'add',
      _runKey,
      '/v',
      'Wolium',
      '/t',
      'REG_SZ',
      '/d',
      '"${installDir()}${Platform.pathSeparator}trackwolium.exe" --background',
      '/f',
    ]);
  } else {
    await Process.run('reg', ['delete', _runKey, '/v', 'Wolium', '/f']);
  }
}
