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
  final Set<String> devices = {};

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
  AppMeta(this.name, this.path, [Set<String>? devices]) : devices = devices ?? <String>{};

  final String name;
  final String path;
  final Set<String> devices;
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

class DeviceInfo {
  const DeviceInfo(this.id, this.name, this.platform, this.lastSync);

  final String id;
  final String name;
  final String platform;
  final int lastSync;
}

class SiteUsage {
  const SiteUsage(this.browser, this.domain, this.ms, [this.title = '', this.url = '']);

  final String browser;
  final String domain;
  final int ms;
  final String title;
  final String url;

  String get displayTitle => title.trim().isNotEmpty ? title.trim() : domain;

  String get openUrl => (url.startsWith('http://') || url.startsWith('https://')) ? url : 'https://$domain';
}

class SiteContrib {
  const SiteContrib(this.start, this.end, this.browser, this.domain, this.title, this.ms);

  final int start;
  final int end;
  final String browser;
  final String domain;
  final String title;
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

  List<DeviceInfo> devices() {
    final db = _open();
    if (db == null) return [];
    try {
      return db
          .select('SELECT id, name, platform, last_sync FROM devices ORDER BY name')
          .map((r) => DeviceInfo(r['id'] as String, r['name'] as String, r['platform'] as String, r['last_sync'] as int))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static bool _hasLocal(Set<String> devices) => devices.isEmpty || devices.contains('local');
  static List<String> _remoteIds(Set<String> devices) => [for (final d in devices) if (d != 'local') d];

  List<AppUsage> day(String day, {Set<String> devices = const {'local'}}) => range(day, day, devices: devices);

  List<AppUsage> range(String from, String to, {Set<String> devices = const {'local'}}) {
    final db = _open();
    if (db == null) return [];
    final map = <String, AppUsage>{};
    final names = this.names(devices: devices);
    void feed(Iterable<Row> rows, {String? forcedDevice}) {
      for (final r in rows) {
        final state = r['state'] as int;
        if (state < 0 || state > 3) continue;
        final app = r['app'] as String;
        final u = map.putIfAbsent(app, () {
          final m = names[app];
          return AppUsage(app, m?.name ?? '')..path = m?.path ?? '';
        });
        u.ms[state] += r['ms'] as int;
        final dev = forcedDevice ?? (r['device'] as String? ?? '');
        if (dev.isNotEmpty) u.devices.add(dev);
      }
    }

    try {
      if (_hasLocal(devices)) {
        feed(db.select('SELECT app, state, ms FROM usage WHERE day BETWEEN ? AND ?', [from, to]), forcedDevice: 'local');
      }
      final remotes = _remoteIds(devices);
      if (remotes.isNotEmpty) {
        try {
          final ph = List.filled(remotes.length, '?').join(',');
          feed(db.select('SELECT device, app, state, ms FROM remote_usage WHERE device IN ($ph) AND day BETWEEN ? AND ?', [...remotes, from, to]));
        } catch (_) {}
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

  static String? browserIdForApp(String app) {
    final a = app.toLowerCase();
    if (a == 'chrome.exe' || a.contains('google-chrome') || a == 'com.android.chrome' || a == 'chromium.exe' || a.contains('chromium')) return 'chrome';
    if (a == 'msedge.exe' || a.contains('microsoft-edge') || a == 'com.microsoft.emmx' || a.contains('msedge')) return 'edge';
    if (a == 'opera.exe' || a == 'opera_gx.exe' || a.contains('opera') || a == 'com.opera.browser' || a == 'com.opera.gx') return 'opera';
    if (a == 'brave.exe' || a.contains('brave') || a == 'com.brave.browser') return 'brave';
    if (a == 'vivaldi.exe' || a.contains('vivaldi')) return 'vivaldi';
    if (a == 'browser.exe' || a.contains('yandex')) return 'yandex';
    if (a == 'arc.exe' || a == 'arc' || a.contains('arc browser')) return 'arc';
    if (a == 'firefox.exe' || a.contains('firefox') || a == 'org.mozilla.firefox' || a == 'zen.exe' || a.contains('zen browser') || a == 'librewolf.exe' || a.contains('librewolf') || a == 'floorp.exe' || a.contains('floorp') || a == 'waterfox.exe' || a.contains('waterfox')) return 'firefox';
    return null;
  }

  Map<String, List<SiteUsage>> browserSites(String from, String to, {Set<String> devices = const {'local'}}) {
    final db = _open();
    final out = <String, List<SiteUsage>>{};
    if (db == null) return out;
    final agg = <String, Map<String, ({int ms, String title, String url})>>{};
    void feed(Iterable<Row> rows, {bool withMeta = true}) {
      for (final r in rows) {
        final b = (r['browser'] as String).toLowerCase();
        final d = r['domain'] as String;
        final ms = r['ms'] as int;
        if (ms <= 0 || d.isEmpty) continue;
        final t = withMeta ? (r['title'] as String? ?? '').trim() : '';
        final u = withMeta ? (r['url'] as String? ?? '').trim() : '';
        final map = agg.putIfAbsent(b, () => {});
        final prev = map[d];
        map[d] = (
          ms: (prev?.ms ?? 0) + ms,
          title: t.isNotEmpty ? t : (prev?.title ?? ''),
          url: u.isNotEmpty ? u : (prev?.url ?? ''),
        );
      }
    }

    if (_hasLocal(devices)) {
      try {
        feed(db.select('''
          SELECT b.browser, b.domain, SUM(b.ms) AS ms,
            COALESCE((SELECT b2.title FROM browser_usage b2 WHERE b2.browser = b.browser AND b2.domain = b.domain AND b2.day BETWEEN ?1 AND ?2 AND b2.title != '' ORDER BY b2.day DESC LIMIT 1), '') AS title,
            COALESCE((SELECT b2.url FROM browser_usage b2 WHERE b2.browser = b.browser AND b2.domain = b.domain AND b2.day BETWEEN ?1 AND ?2 AND b2.url != '' ORDER BY b2.day DESC LIMIT 1), '') AS url
          FROM browser_usage b WHERE b.day BETWEEN ?1 AND ?2 GROUP BY b.browser, b.domain
        ''', [from, to]));
      } catch (_) {
        try {
          feed(db.select('SELECT browser, domain, SUM(ms) AS ms FROM browser_usage WHERE day BETWEEN ? AND ? GROUP BY browser, domain', [from, to]), withMeta: false);
        } catch (_) {}
      }
    }
    final remotes = _remoteIds(devices);
    if (remotes.isNotEmpty) {
      final ph = List.filled(remotes.length, '?').join(',');
      final ph2 = List.generate(remotes.length, (i) => '?${3 + i}').join(',');
      try {
        feed(db.select('''
          SELECT b.browser, b.domain, SUM(b.ms) AS ms,
            COALESCE((SELECT b2.title FROM remote_browser_usage b2 WHERE b2.device IN ($ph2) AND b2.browser = b.browser AND b2.domain = b.domain AND b2.day BETWEEN ?1 AND ?2 AND b2.title != '' ORDER BY b2.day DESC LIMIT 1), '') AS title,
            COALESCE((SELECT b2.url FROM remote_browser_usage b2 WHERE b2.device IN ($ph2) AND b2.browser = b.browser AND b2.domain = b.domain AND b2.day BETWEEN ?1 AND ?2 AND b2.url != '' ORDER BY b2.day DESC LIMIT 1), '') AS url
          FROM remote_browser_usage b WHERE b.day BETWEEN ?1 AND ?2 AND b.device IN ($ph2) GROUP BY b.browser, b.domain
        ''', [from, to, ...remotes]));
      } catch (_) {
        try {
          feed(db.select('SELECT browser, domain, SUM(ms) AS ms FROM remote_browser_usage WHERE device IN ($ph) AND day BETWEEN ? AND ? GROUP BY browser, domain', [...remotes, from, to]), withMeta: false);
        } catch (_) {}
      }
    }

    agg.forEach((b, m) {
      final list = m.entries.map((e) => SiteUsage(b, e.key, e.value.ms, e.value.title, e.value.url)).toList()
        ..sort((a, b) => b.ms.compareTo(a.ms));
      out[b] = list;
    });
    return out;
  }

  List<SiteContrib> browserContribs(DateTime first, int w0, int w1, int bin, {Set<String> devices = const {'local'}}) {
    final db = _open();
    if (db == null) return [];
    final out = <SiteContrib>[];
    final a = first.add(Duration(seconds: w0));
    final b = first.add(Duration(seconds: w1));
    String key(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    final ka = key(a);
    final kb = key(b);

    void feed(Iterable<Row> rows) {
      for (final r in rows) {
        final ms = r['ms'] as int;
        if (ms <= 0) continue;
        final midnight = DateTime.parse('${r['day']}T00:00:00');
        final start = midnight.add(Duration(seconds: (r['bslot'] as int) * 300)).difference(first).inSeconds;
        final end = start + bin * 300;
        out.add(SiteContrib(start, end, (r['browser'] as String).toLowerCase(), r['domain'] as String, (r['title'] as String? ?? '').trim(), ms));
      }
    }

    if (_hasLocal(devices)) {
      try {
        feed(db.select(
          "SELECT day, (slot / ?3) * ?3 AS bslot, browser, domain, MAX(title) AS title, SUM(ms) AS ms FROM browser_timeline WHERE day BETWEEN ?1 AND ?2 GROUP BY day, slot / ?3, browser, domain",
          [ka, kb, bin],
        ));
      } catch (_) {}
    }
    final remotes = _remoteIds(devices);
    if (remotes.isNotEmpty) {
      try {
        final ph = List.generate(remotes.length, (i) => '?${4 + i}').join(',');
        feed(db.select(
          "SELECT day, (slot / ?3) * ?3 AS bslot, browser, domain, MAX(title) AS title, SUM(ms) AS ms FROM remote_browser_timeline WHERE day BETWEEN ?1 AND ?2 AND device IN ($ph) GROUP BY day, slot / ?3, browser, domain",
          [ka, kb, bin, ...remotes],
        ));
      } catch (_) {}
    }
    return out;
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

  List<Contrib> contribs(DateTime first, int w0, int w1, int bin, bool sessions, {bool realFocus = false, Set<String> devices = const {'local'}}) {
    final db = _open();
    if (db == null) return [];
    final out = <Contrib>[];
    if (realFocus) sessions = false;
    final hasLocal = _hasLocal(devices);
    final remotes = _remoteIds(devices);
    final firstUnix = first.millisecondsSinceEpoch ~/ 1000;
    int? cutoff;
    if (sessions && hasLocal) {
      try {
        final r = db.select('SELECT MIN(start) AS m FROM sessions');
        if (r.isNotEmpty && r.first['m'] != null) cutoff = (r.first['m'] as int) - firstUnix;
      } catch (_) {}
    }
    try {
      final a = first.add(Duration(seconds: w0));
      final b = first.add(Duration(seconds: w1));
      String key(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      final idle = <String, int>{};
      if (realFocus && hasLocal) {
        try {
          for (final r in db.select('SELECT day, (slot / ?3) * ?3 AS bslot, app, SUM(ms) AS ms FROM afk WHERE day BETWEEN ?1 AND ?2 GROUP BY day, slot / ?3, app', [key(a), key(b), bin])) {
            idle['${r['day']}|${r['bslot']}|${r['app']}'] = r['ms'] as int;
          }
        } catch (_) {}
      }
      if (hasLocal) {
        final rows = db.select(
            'SELECT day, (slot / ?3) * ?3 AS bslot, app, state, SUM(ms) AS ms FROM timeline WHERE day BETWEEN ?1 AND ?2 GROUP BY day, slot / ?3, app, state',
            [key(a), key(b), bin]);
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
      }
      if (remotes.isNotEmpty) {
        try {
          final ka = key(a);
          final kb = key(b);
          final ph = List.generate(remotes.length, (i) => '?${4 + i}').join(',');
          final rows = db.select(
              'SELECT day, (slot / ?3) * ?3 AS bslot, app, state, SUM(ms) AS ms FROM remote_timeline WHERE day BETWEEN ?1 AND ?2 AND device IN ($ph) GROUP BY day, slot / ?3, app, state',
              [ka, kb, bin, ...remotes]);
          for (final r in rows) {
            final midnight = DateTime.parse('${r['day']}T00:00:00');
            final start = midnight.add(Duration(seconds: (r['bslot'] as int) * 300)).difference(first).inSeconds;
            final end = start + bin * 300;
            final ms = r['ms'] as int;
            if (ms == 0) continue;
            out.add(Contrib(start, end, r['app'] as String, r['state'] as int, ms));
          }
        } catch (_) {}
      }
    } catch (_) {}
    if (cutoff != null && hasLocal) {
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

  Set<String> windowed() {
    final db = _open();
    final out = <String>{};
    if (db == null) return out;
    try {
      for (final r in db.select('SELECT DISTINCT app FROM usage WHERE state IN (0, 1, 2) AND ms > 0')) {
        out.add(r['app'] as String);
      }
    } catch (_) {}
    return out;
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

  Map<String, AppMeta> names({Set<String> devices = const {'local'}}) {
    final db = _open();
    final out = <String, AppMeta>{};
    if (db == null) return out;
    final remotes = _remoteIds(devices);
    if (remotes.isNotEmpty) {
      try {
        final ph = List.filled(remotes.length, '?').join(',');
        for (final r in db.select('SELECT device, app, name, path FROM remote_apps WHERE device IN ($ph)', remotes)) {
          final app = r['app'] as String;
          final dev = r['device'] as String;
          final rName = r['name'] as String;
          final rPath = r['path'] as String;
          final cur = out[app];
          if (cur == null) {
            out[app] = AppMeta(rName, rPath, {dev});
          } else {
            out[app] = AppMeta(cur.name.isNotEmpty ? cur.name : rName, cur.path.isNotEmpty ? cur.path : rPath, {...cur.devices, dev});
          }
        }
      } catch (_) {}
    }
    if (_hasLocal(devices)) {
      try {
        for (final r in db.select('SELECT app, name, path FROM apps')) {
          final app = r['app'] as String;
          final lName = r['name'] as String;
          final lPath = r['path'] as String;
          final cur = out[app];
          out[app] = cur == null
              ? AppMeta(lName, lPath, {'local'})
              : AppMeta(lName.isNotEmpty ? lName : cur.name, lPath.isNotEmpty ? lPath : cur.path, {...cur.devices, 'local'});
        }
      } catch (_) {
        try {
          for (final r in db.select('SELECT app, name FROM apps')) {
            final app = r['app'] as String;
            final lName = r['name'] as String;
            final cur = out[app];
            out[app] = cur == null
                ? AppMeta(lName, '', {'local'})
                : AppMeta(lName.isNotEmpty ? lName : cur.name, cur.path, {...cur.devices, 'local'});
          }
        } catch (_) {}
      }
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
      u.devices.add('local');
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
