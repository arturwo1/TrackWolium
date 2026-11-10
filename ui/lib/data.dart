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

class Slot {
  Slot(this.slot, this.app, this.state, this.ms);

  final int slot;
  final String app;
  final int state;
  final int ms;
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
    final names = this.names();
    try {
      for (final r in db.select('SELECT app, state, ms FROM usage WHERE day = ?', [day])) {
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

  List<Slot> timeline(String day) {
    final db = _open();
    if (db == null) return [];
    try {
      return db
          .select('SELECT slot, app, state, ms FROM timeline WHERE day = ?', [day])
          .map((r) => Slot(r['slot'] as int, r['app'] as String, r['state'] as int, r['ms'] as int))
          .toList();
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
