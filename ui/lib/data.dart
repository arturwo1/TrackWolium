import 'dart:io';
import 'package:sqlite3/sqlite3.dart';
import 'l10n.dart';
import 'win.dart';

class AppUsage {
  AppUsage(this.app, [this.name = '']);

  final String app;
  String name;
  String path = '';
  int? now;

  String get title => name.isNotEmpty ? name : prettyApp(app);
  final List<int> ms = [0, 0, 0, 0];

  int get visible => ms[0] + ms[1] + ms[2];
  int get total => visible + ms[3];
}

String installDir() => File(Platform.resolvedExecutable).parent.path;

String dataDir() {
  final base = Platform.environment['LOCALAPPDATA'] ?? installDir();
  return '$base${Platform.pathSeparator}DTSys${Platform.pathSeparator}Wolium';
}

void migrateLegacyData() {
  try {
    final legacy = Directory('${installDir()}${Platform.pathSeparator}userdata');
    final now = Directory(dataDir());
    if (!legacy.existsSync() || now.existsSync()) return;
    now.parent.createSync(recursive: true);
    legacy.renameSync(now.path);
  } catch (_) {}
}

String prettyApp(String exe) {
  var n = exe.toLowerCase().endsWith('.exe') ? exe.substring(0, exe.length - 4) : exe;
  if (n.isEmpty) return exe;
  return n[0].toUpperCase() + n.substring(1);
}

String dbPath() => '${dataDir()}${Platform.pathSeparator}usage.db';

String formatMs(int ms) {
  final s = ms ~/ 1000;
  if (s < 60) return '$s${tr('unitS')}';
  final m = s ~/ 60;
  if (m < 60) return '$m${tr('unitM')} ${s % 60}${tr('unitS')}';
  final h = m ~/ 60;
  return '$h${tr('unitH')} ${m % 60}${tr('unitM')}';
}

String langFile() => '${dataDir()}${Platform.pathSeparator}lang';

void loadLanguage() {
  try {
    final f = File(langFile());
    if (f.existsSync()) {
      final code = f.readAsStringSync().trim();
      if (languages.containsKey(code)) language.value = code;
    }
  } catch (_) {}
}

void saveLanguage(String code) {
  language.value = code;
  try {
    Directory(dataDir()).createSync(recursive: true);
    File(langFile()).writeAsStringSync('$code\n');
  } catch (_) {}
}

class AppMeta {
  AppMeta(this.name, this.path);

  final String name;
  final String path;
}

class Contrib {
  const Contrib(this.start, this.end, this.app, this.state, this.ms);

  final int start;
  final int end;
  final String app;
  final int state;
  final int ms;
}

class PresenceRow {
  const PresenceRow(this.sec, this.clientId, this.name, this.details, this.state);

  final int sec;
  final String clientId;
  final String name;
  final String details;
  final String state;
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

  List<AppUsage> day(String day) => range(day, day);

  List<AppUsage> range(String from, String to) {
    final db = _open();
    if (db == null) return [];
    final map = <String, AppUsage>{};
    final names = this.names();
    try {
      for (final r in db.select('SELECT app, state, ms FROM usage WHERE day BETWEEN ? AND ?', [from, to])) {
        final state = r['state'] as int;
        if (state < 0 || state > 3) continue;
        map.putIfAbsent(r['app'] as String, () {
          final m = names[r['app'] as String];
          return AppUsage(r['app'] as String, m?.name ?? '')..path = m?.path ?? '';
        }).ms[state] += r['ms'] as int;
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

  List<Contrib> contribs(DateTime first, int w0, int w1, int bin, bool sessions) {
    final db = _open();
    if (db == null) return [];
    final out = <Contrib>[];
    final origin = DateTime.utc(first.year, first.month, first.day);
    final firstUnix = first.millisecondsSinceEpoch ~/ 1000;
    int? cutoff;
    if (sessions) {
      try {
        final r = db.select('SELECT MIN(start) AS m FROM sessions');
        if (r.isNotEmpty && r.first['m'] != null) cutoff = (r.first['m'] as int) - firstUnix;
      } catch (_) {}
    }
    try {
      final a = first.add(Duration(seconds: w0));
      final b = first.add(Duration(seconds: w1));
      String key(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      final rows = db.select(
          'SELECT day, (slot / ?3) * ?3 AS bslot, app, state, SUM(ms) AS ms FROM timeline WHERE day BETWEEN ?1 AND ?2 GROUP BY day, slot / ?3, app, state',
          [key(a), key(b), bin]);
      for (final r in rows) {
        final d = DateTime.parse('${r['day']}T00:00:00Z').difference(origin).inDays;
        final start = d * 86400 + (r['bslot'] as int) * 300;
        final end = start + bin * 300;
        if (cutoff != null && end > cutoff) continue;
        out.add(Contrib(start, end, r['app'] as String, r['state'] as int, r['ms'] as int));
      }
    } catch (_) {}
    if (cutoff != null) {
      try {
        for (final r in db.select('SELECT app, state, start, stop FROM sessions WHERE stop >= ?1 AND start <= ?2', [firstUnix + w0, firstUnix + w1])) {
          final start = (r['start'] as int) - firstUnix;
          final end = (r['stop'] as int) - firstUnix;
          out.add(Contrib(start, end, r['app'] as String, r['state'] as int, (end - start) * 1000));
        }
      } catch (_) {}
    }
    return out;
  }

  List<PresenceRow> presence(DateTime first, int w0, int w1) {
    final db = _open();
    if (db == null) return [];
    final firstUnix = first.millisecondsSinceEpoch ~/ 1000;
    try {
      final rows = db.select('SELECT ts, client_id, name, details, state FROM presence WHERE ts >= ?1 AND ts <= ?2 ORDER BY ts', [firstUnix + w0, firstUnix + w1]);
      return [for (final r in rows) PresenceRow((r['ts'] as int) - firstUnix, r['client_id'] as String, r['name'] as String, r['details'] as String, r['state'] as String)];
    } catch (_) {
      return [];
    }
  }

  Map<String, AppMeta> names() {
    final db = _open();
    final out = <String, AppMeta>{};
    if (db == null) return out;
    try {
      for (final r in db.select('SELECT app, name, path FROM apps')) {
        out[r['app'] as String] = AppMeta(r['name'] as String, r['path'] as String);
      }
    } catch (_) {
      try {
        for (final r in db.select('SELECT app, name FROM apps')) {
          out[r['app'] as String] = AppMeta(r['name'] as String, '');
        }
      } catch (_) {}
    }
    return out;
  }

  List<AppUsage>? live() {
    final text = readLive();
    if (text == null) return null;
    final names = this.names();
    final list = <AppUsage>[];
    for (final line in text.split('\n')) {
      if (!line.startsWith('A ')) continue;
      final p = line.split(' ');
      if (p.length < 8) continue;
      final u = AppUsage(p.sublist(7).join(' '), '');
      u.name = names[u.app]?.name ?? '';
      u.path = names[u.app]?.path ?? '';
      if (p[1] == '1') u.now = int.tryParse(p[2]);
      for (var i = 0; i < 4; i++) {
        u.ms[i] = int.tryParse(p[3 + i]) ?? 0;
      }
      if (u.visible > 0) list.add(u);
    }
    list.sort((a, b) {
      final c = b.visible.compareTo(a.visible);
      return c != 0 ? c : b.total.compareTo(a.total);
    });
    return list;
  }

  bool get paused => File('${dataDir()}${Platform.pathSeparator}paused').existsSync();

  void setPaused(bool v) {
    final f = File('${dataDir()}${Platform.pathSeparator}paused');
    try {
      if (v) {
        f.writeAsStringSync('1');
      } else if (f.existsSync()) {
        f.deleteSync();
      }
    } catch (_) {}
  }

  Duration? sinceHeartbeat() {
    final ms = heartbeatAgeMs();
    return ms == null ? null : Duration(milliseconds: ms < 0 ? 0 : ms);
  }

  void close() {
    _db?.dispose();
    _db = null;
  }
}

class Settings {
  Settings._();

  static Settings load() => Settings._();

  String get _consent => '${dataDir()}${Platform.pathSeparator}consent';

  bool get accepted => File(_consent).existsSync();

  String get _noUpdates => '${dataDir()}${Platform.pathSeparator}noupdates';

  bool get autoUpdate => !File(_noUpdates).existsSync();

  set autoUpdate(bool v) {
    try {
      Directory(dataDir()).createSync(recursive: true);
      if (v) {
        if (File(_noUpdates).existsSync()) File(_noUpdates).deleteSync();
      } else {
        File(_noUpdates).writeAsStringSync('1');
      }
    } catch (_) {}
  }

  bool flag(String name) => File('${dataDir()}${Platform.pathSeparator}$name').existsSync();

  void setFlag(String name, bool v) {
    try {
      final f = File('${dataDir()}${Platform.pathSeparator}$name');
      if (v) {
        Directory(dataDir()).createSync(recursive: true);
        f.writeAsStringSync('1');
      } else if (f.existsSync()) {
        f.deleteSync();
      }
    } catch (_) {}
  }

  set accepted(bool v) {
    try {
      if (v) {
        Directory(dataDir()).createSync(recursive: true);
        File(_consent).writeAsStringSync('1');
      } else if (File(_consent).existsSync()) {
        File(_consent).deleteSync();
      }
    } catch (_) {}
  }
}

Future<void> startService() async {
  final exe = '${installDir()}${Platform.pathSeparator}trackwolium.exe';
  if (!File(exe).existsSync()) return;
  try {
    await Process.start(exe, ['--background'], mode: ProcessStartMode.detached);
  } catch (_) {}
}

const _runKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';

bool? autostartCache;

Future<bool> autostartEnabled() async {
  final r = await Process.run('reg', ['query', _runKey, '/v', 'Wolium']);
  autostartCache = r.exitCode == 0;
  return autostartCache!;
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
