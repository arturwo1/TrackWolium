import 'package:flutter/foundation.dart';
import 'dart:math' as math;
import 'dart:io';
import 'package:sqlite3/sqlite3.dart';
import 'l10n.dart';
import 'posix.dart';
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

String? androidBase;

String dataDir() {
  if (Platform.isAndroid && androidBase != null) return '$androidBase${Platform.pathSeparator}Wolium';
  if (Platform.isMacOS) {
    final home = Platform.environment['HOME'] ?? installDir();
    return '$home/Library/Application Support/DTSys/Wolium';
  }
  if (Platform.isLinux) {
    final x = Platform.environment['XDG_DATA_HOME'];
    final home = Platform.environment['HOME'] ?? installDir();
    return '${x != null && x.isNotEmpty ? x : '$home/.local/share'}/DTSys/Wolium';
  }
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

class ResAgg {
  int cpuMs = 0;
  int ramSum = 0;
  int ramN = 0;
  int peakKb = 0;
  int ior = 0;
  int iow = 0;

  int get ramKb => ramN == 0 ? 0 : ramSum ~/ ramN;

  bool get empty => cpuMs == 0 && ramN == 0 && peakKb == 0 && ior == 0 && iow == 0;
}

class ResPoint {
  const ResPoint(this.start, this.end, this.app, this.cpuMs, this.ramKb, this.peakKb, this.ior, this.iow);

  final int start;
  final int end;
  final String app;
  final int cpuMs;
  final int ramKb;
  final int peakKb;
  final int ior;
  final int iow;
}

class SysPoint {
  const SysPoint(this.t, this.kind, this.total, this.free);

  final int t;
  final String kind;
  final int total;
  final int free;
}

class PresenceRow {
  const PresenceRow(this.sec, this.clientId, this.name, this.details, this.state, this.raw);

  final int sec;
  final String clientId;
  final String name;
  final String details;
  final String state;
  final String raw;
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
    final list = map.values.where((a) => a.total > 0).toList();
    if (list.any((a) => a.visible > 0)) list.removeWhere((a) => a.visible == 0);
    list.sort((a, b) {
      final c = b.visible.compareTo(a.visible);
      return c != 0 ? c : b.total.compareTo(a.total);
    });
    return list;
  }

  Map<String, int> afk(String from, String to) {
    final db = _open();
    final out = <String, int>{};
    if (db == null) return out;
    try {
      for (final r in db.select('SELECT app, SUM(ms) AS ms FROM afk WHERE day BETWEEN ? AND ? GROUP BY app', [from, to])) {
        out[r['app'] as String] = r['ms'] as int;
      }
    } catch (_) {}
    return out;
  }

  int maxSpan = -1;
  int maxSpanAt = 0;

  int sessionLowerSlack(dynamic db) {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (maxSpan < 0 || now - maxSpanAt > 600) {
      try {
        final r = db.select('SELECT MAX(stop - start) AS m FROM sessions');
        maxSpan = r.isNotEmpty && r.first['m'] != null ? r.first['m'] as int : 0;
      } catch (_) {
        maxSpan = 0;
      }
      maxSpanAt = now;
    }
    return maxSpan + (now - maxSpanAt) + 60;
  }

  List<Contrib> contribs(DateTime first, int w0, int w1, int bin, bool sessions, {bool realFocus = false}) {
    final db = _open();
    if (db == null) return [];
    final out = <Contrib>[];
    if (realFocus) sessions = false;
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
      final idle = <String, int>{};
      if (realFocus) {
        try {
          for (final r in db.select('SELECT day, (slot / ?3) * ?3 AS bslot, app, SUM(ms) AS ms FROM afk WHERE day BETWEEN ?1 AND ?2 GROUP BY day, slot / ?3, app', [key(a), key(b), bin])) {
            idle['${r['day']}|${r['bslot']}|${r['app']}'] = r['ms'] as int;
          }
        } catch (_) {}
      }
      for (final r in rows) {
        final midnight = DateTime.parse('${r['day']}T00:00:00');
        final start = midnight.add(Duration(seconds: (r['bslot'] as int) * 300)).difference(first).inSeconds;
        final end = start + bin * 300;
        if (cutoff != null && end > cutoff) continue;
        var ms = r['ms'] as int;
        if (realFocus && r['state'] == 0) ms = math.max(0, ms - (idle['${r['day']}|${r['bslot']}|${r['app']}'] ?? 0));
        if (ms == 0) continue;
        out.add(Contrib(start, end, r['app'] as String, r['state'] as int, ms));
      }
    } catch (_) {}
    if (cutoff != null) {
      try {
        final lowest = firstUnix + w0 - sessionLowerSlack(db);
        for (final r in db.select('SELECT app, state, start, stop FROM sessions WHERE start >= ?3 AND start <= ?2 AND stop >= ?1', [firstUnix + w0, firstUnix + w1, lowest])) {
          final start = (r['start'] as int) - firstUnix;
          final end = (r['stop'] as int) - firstUnix;
          out.add(Contrib(start, end, r['app'] as String, r['state'] as int, (end - start) * 1000));
        }
      } catch (_) {}
    }
    return out;
  }

  Map<String, ResAgg> resources(String from, String to) {
    final db = _open();
    final out = <String, ResAgg>{};
    if (db == null) return out;
    try {
      for (final r in db.select('SELECT app, SUM(cpu) AS cpu, SUM(ram) AS ram, SUM(n) AS n, MAX(peak) AS peak, SUM(ior) AS ior, SUM(iow) AS iow FROM res WHERE day BETWEEN ? AND ? GROUP BY app', [from, to])) {
        out[r['app'] as String] = ResAgg()
          ..cpuMs = r['cpu'] as int
          ..ramSum = r['ram'] as int
          ..ramN = r['n'] as int
          ..peakKb = r['peak'] as int
          ..ior = r['ior'] as int
          ..iow = r['iow'] as int;
      }
    } catch (_) {}
    return out;
  }

  List<ResPoint> resPoints(DateTime first, int w0, int w1, int bin) {
    final db = _open();
    if (db == null) return [];
    final out = <ResPoint>[];
    try {
      final a = first.add(Duration(seconds: w0));
      final b = first.add(Duration(seconds: w1));
      String key(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      final rows = db.select(
          'SELECT day, (slot / ?3) * ?3 AS bslot, app, SUM(cpu) AS cpu, SUM(ram) AS ram, SUM(n) AS n, MAX(peak) AS peak, SUM(ior) AS ior, SUM(iow) AS iow FROM res WHERE day BETWEEN ?1 AND ?2 GROUP BY day, slot / ?3, app',
          [key(a), key(b), bin]);
      for (final r in rows) {
        final midnight = DateTime.parse('${r['day']}T00:00:00');
        final start = midnight.add(Duration(seconds: (r['bslot'] as int) * 300)).difference(first).inSeconds;
        final n = r['n'] as int;
        out.add(ResPoint(start, start + bin * 300, r['app'] as String, r['cpu'] as int, n == 0 ? 0 : (r['ram'] as int) ~/ n, r['peak'] as int, r['ior'] as int, r['iow'] as int));
      }
    } catch (_) {}
    return out;
  }

  List<SysPoint> sysPoints(DateTime first, int w0, int w1) {
    final db = _open();
    if (db == null) return [];
    final firstUnix = first.millisecondsSinceEpoch ~/ 1000;
    try {
      final rows = db.select('SELECT ts, kind, a, b FROM sysmon WHERE ts >= ?1 AND ts <= ?2 ORDER BY ts', [firstUnix + w0, firstUnix + w1]);
      return [for (final r in rows) SysPoint((r['ts'] as int) - firstUnix, r['kind'] as String, r['a'] as int, r['b'] as int)];
    } catch (_) {
      return [];
    }
  }

  List<int> forecastHistory() {
    final db = _open();
    if (db == null) return [0, 0];
    try {
      final since = DateTime.now().subtract(const Duration(days: 30));
      final key = '${since.year}-${since.month.toString().padLeft(2, '0')}-${since.day.toString().padLeft(2, '0')}';
      final r = db.select('SELECT COUNT(*) AS c, COUNT(DISTINCT day) AS d FROM (SELECT DISTINCT day, slot, app FROM timeline WHERE state < 3 AND day >= ?)', [key]);
      if (r.isEmpty) return [0, 0];
      return [r.first['c'] as int, r.first['d'] as int];
    } catch (_) {
      return [0, 0];
    }
  }

  int sysDiskCount() {
    final db = _open();
    if (db == null) return 0;
    try {
      final r = db.select("SELECT COUNT(DISTINCT kind) AS c FROM sysmon WHERE kind LIKE 'disk:%'");
      return r.isEmpty ? 0 : r.first['c'] as int;
    } catch (_) {
      return 0;
    }
  }

  List<PresenceRow> presence(DateTime first, int w0, int w1) {
    final db = _open();
    if (db == null) return [];
    final firstUnix = first.millisecondsSinceEpoch ~/ 1000;
    final args = [firstUnix + w0, firstUnix + w1];
    try {
      final rows = db.select('SELECT ts, client_id, name, details, state, raw FROM presence WHERE ts >= ?1 AND ts <= ?2 ORDER BY ts', args);
      return [for (final r in rows) PresenceRow((r['ts'] as int) - firstUnix, r['client_id'] as String, r['name'] as String, r['details'] as String, r['state'] as String, r['raw'] as String)];
    } catch (_) {
      try {
        final rows = db.select('SELECT ts, client_id, name, details, state FROM presence WHERE ts >= ?1 AND ts <= ?2 ORDER BY ts', args);
        return [for (final r in rows) PresenceRow((r['ts'] as int) - firstUnix, r['client_id'] as String, r['name'] as String, r['details'] as String, r['state'] as String, '')];
      } catch (_) {
        return [];
      }
    }
  }

  Map<String, int> appCats() {
    final db = _open();
    final out = <String, int>{};
    if (db == null) return out;
    try {
      for (final r in db.select('SELECT app, cat FROM appcat')) {
        out[r['app'] as String] = r['cat'] as int;
      }
    } catch (_) {}
    return out;
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
      if (u.total > 0) list.add(u);
    }
    if (list.any((a) => a.visible > 0)) list.removeWhere((a) => a.visible == 0);
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

class MetricPrefs {
  static final ValueNotifier<Set<String>> enabled = ValueNotifier(<String>{});

  static File get _file => File('${dataDir()}${Platform.pathSeparator}metrics');

  static void load() {
    try {
      enabled.value = _file.existsSync() ? _file.readAsStringSync().split(RegExp(r'\s+')).where((e) => e.isNotEmpty).toSet() : <String>{};
    } catch (_) {}
  }

  static bool has(String id) => enabled.value.contains(id);

  static void set(String id, bool on) {
    final next = Set<String>.of(enabled.value);
    if (on) {
      next.add(id);
    } else {
      next.remove(id);
    }
    enabled.value = next;
    try {
      if (next.isEmpty) {
        if (_file.existsSync()) _file.deleteSync();
      } else {
        Directory(dataDir()).createSync(recursive: true);
        _file.writeAsStringSync('${next.join(' ')}\n');
      }
    } catch (_) {}
  }
}

class ColumnPrefs {
  static final ValueNotifier<Set<String>> hidden = ValueNotifier(<String>{});

  static File get _file => File('${dataDir()}${Platform.pathSeparator}columns');

  static Map<String, double> widths = {};
  static List<String> order = [];

  static File get _orderFile => File('${dataDir()}${Platform.pathSeparator}colorder');

  static List<String> sorted(List<String> ids) {
    final idx = {for (var i = 0; i < order.length; i++) order[i]: i};
    final base = {for (var i = 0; i < ids.length; i++) ids[i]: i};
    final out = List<String>.of(ids);
    out.sort((a, b) {
      final x = idx[a] ?? (1000 + base[a]!);
      final y = idx[b] ?? (1000 + base[b]!);
      return x.compareTo(y);
    });
    return out;
  }

  static void move(String drag, String target, List<String> ids) {
    final list = sorted(ids);
    final from = list.indexOf(drag);
    final to = list.indexOf(target);
    if (from < 0 || to < 0 || from == to) return;
    list.removeAt(from);
    list.insert(to, drag);
    order = list;
    hidden.value = Set<String>.of(hidden.value);
    persistOrder();
  }

  static void persistOrder() {
    try {
      if (order.isEmpty) {
        if (_orderFile.existsSync()) _orderFile.deleteSync();
      } else {
        Directory(dataDir()).createSync(recursive: true);
        _orderFile.writeAsStringSync('${order.join('\n')}\n');
      }
    } catch (_) {}
  }

  static File get _widthFile => File('${dataDir()}${Platform.pathSeparator}colwidths');

  static void load() {
    try {
      hidden.value = _file.existsSync() ? _file.readAsStringSync().split(RegExp(r'\s+')).where((e) => e.isNotEmpty).toSet() : <String>{};
    } catch (_) {}
    try {
      final next = <String, double>{};
      if (_widthFile.existsSync()) {
        for (final line in _widthFile.readAsLinesSync()) {
          final i = line.indexOf('=');
          final w = i < 0 ? null : double.tryParse(line.substring(i + 1).trim());
          if (w != null && w >= 40 && w <= 800) next[line.substring(0, i).trim()] = w;
        }
      }
      widths = next;
    } catch (_) {}
    try {
      order = _orderFile.existsSync() ? _orderFile.readAsLinesSync().map((e) => e.trim()).where((e) => e.isNotEmpty).toList() : [];
    } catch (_) {}
  }

  static void setWidth(String id, double w, {bool persist = true}) {
    widths = {...widths, id: w};
    hidden.value = Set<String>.of(hidden.value);
    if (persist) persistWidths();
  }

  static void resetWidths() {
    widths = {};
    order = [];
    hidden.value = Set<String>.of(hidden.value);
    persistWidths();
    persistOrder();
  }

  static void persistWidths() {
    try {
      if (widths.isEmpty) {
        if (_widthFile.existsSync()) _widthFile.deleteSync();
      } else {
        Directory(dataDir()).createSync(recursive: true);
        _widthFile.writeAsStringSync('${widths.entries.map((e) => '${e.key}=${e.value.round()}').join('\n')}\n');
      }
    } catch (_) {}
  }

  static bool shown(String id) => !hidden.value.contains(id);

  static void set(String id, bool on) {
    final next = Set<String>.of(hidden.value);
    if (on) {
      next.remove(id);
    } else {
      next.add(id);
    }
    hidden.value = next;
    try {
      if (next.isEmpty) {
        if (_file.existsSync()) _file.deleteSync();
      } else {
        Directory(dataDir()).createSync(recursive: true);
        _file.writeAsStringSync('${next.join(' ')}\n');
      }
    } catch (_) {}
  }
}

Future<void> startService() async {
  if (Platform.isLinux || Platform.isMacOS) return posixStartService();
  if (!Platform.isWindows) return;
  final exe = '${installDir()}${Platform.pathSeparator}trackwolium.exe';
  if (!File(exe).existsSync()) return;
  try {
    await Process.start(exe, ['--background'], mode: ProcessStartMode.detached);
  } catch (_) {}
}

const _runKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';

bool? autostartCache;

Future<bool> autostartEnabled() async {
  if (!Platform.isWindows) return autostartCache = posixAutostartEnabled();
  final r = await Process.run('reg', ['query', _runKey, '/v', 'Wolium']);
  autostartCache = r.exitCode == 0;
  return autostartCache!;
}

Future<void> setAutostart(bool on) async {
  if (!Platform.isWindows) {
    posixSetAutostart(on);
    autostartCache = on;
    return;
  }
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

class Hidden {
  static final ValueNotifier<Map<String, String>> apps = ValueNotifier({});

  static File get _file => File('${dataDir()}${Platform.pathSeparator}hidden.txt');

  static void load() {
    try {
      final map = <String, String>{};
      if (_file.existsSync()) {
        for (final line in _file.readAsLinesSync()) {
          if (line.isEmpty) continue;
          final i = line.indexOf('\t');
          map[i < 0 ? line : line.substring(0, i)] = i < 0 ? line : line.substring(i + 1);
        }
      }
      apps.value = map;
    } catch (_) {}
  }

  static void _save() {
    try {
      Directory(dataDir()).createSync(recursive: true);
      _file.writeAsStringSync(apps.value.entries.map((e) => '${e.key}\t${e.value}\n').join());
    } catch (_) {}
  }

  static void hide(String app, String title) {
    apps.value = {...apps.value, app: title};
    _save();
  }

  static void show(String app) {
    apps.value = Map.of(apps.value)..remove(app);
    _save();
  }

  static bool has(String app) => apps.value.containsKey(app);
}
