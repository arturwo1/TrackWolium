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

String cleanSiteTitle(String rawTitle, String domain) {
  var t = rawTitle.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (t.isEmpty) return '';
  final low = t.toLowerCase();
  const schemes = [
    'http://',
    'https://',
    'file://',
    'about:',
    'chrome:',
    'edge:',
    'opera:',
    'moz-extension:',
    'view-source:',
  ];
  for (final s in schemes) {
    if (low.startsWith(s)) return '';
  }
  final d = domain.trim().toLowerCase();
  final bare = d.startsWith('www.') ? d.substring(4) : d;
  if (d.isNotEmpty) {
    if (low == d || low == bare || low == 'www.$bare') return '';
    if (low.startsWith('$d/') ||
        low.startsWith('$bare/') ||
        low.startsWith('www.$bare/') ||
        low.startsWith('$d:') ||
        low.startsWith('$bare:')) {
      return '';
    }
  }
  if (!t.contains(' ') && RegExp(r'^[a-z0-9-]+(\.[a-z0-9-]+)+(:\d+)?(/.*)?$', caseSensitive: false).hasMatch(t)) {
    return '';
  }
  return t;
}

class SysPoint {
  const SysPoint(this.t, this.kind, this.total, this.free, [this.device = 'local']);

  final int t;
  final String kind;
  final int total;
  final int free;
  final String device;
}

class GlobalPowerRow {
  int count = 0;
  int durationMs = 0;
}

class GlobalDiskRow {
  const GlobalDiskRow(this.mount, this.totalKb, this.freeKb);

  final String mount;
  final int totalKb;
  final int freeKb;

  int get usedKb => math.max(0, totalKb - freeKb);
}

class GlobalDeviceStats {
  GlobalDeviceStats(this.id, this.name, this.platform);

  final String id;
  final String name;
  final String platform;
  int ramTotalKb = 0;
  int ramFreeKb = 0;
  int get ramUsedKb => math.max(0, ramTotalKb - ramFreeKb);
  final List<GlobalDiskRow> disks = [];
  int focusedMs = 0;
  int visibleMs = 0;
  int totalMs = 0;
  int afkMs = 0;
  int opens = 0;
  int notifs = 0;
  int unlocks = 0;
  final Map<String, GlobalPowerRow> power = {};
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

  String get cleanTitle => cleanSiteTitle(title, domain);

  String get displayTitle {
    final ct = cleanTitle;
    return ct.isNotEmpty ? ct : domain;
  }

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

class DeviceAppUsage {
  const DeviceAppUsage(this.device, this.usage);

  final String device;
  final AppUsage usage;
}

class SessionRecord {
  const SessionRecord(this.app, this.state, this.start, this.stop, this.device);

  final String app;
  final int state;
  final int start;
  final int stop;
  final String device;
}

class ActivityStats {
  const ActivityStats({this.unlocks = 0, this.opens = const {}, this.notifs = const {}});

  final int unlocks;
  final Map<String, int> opens;
  final Map<String, int> notifs;
}

class StatPoint {
  const StatPoint(this.start, this.end, this.app, this.kind, this.count);

  final int start;
  final int end;
  final String app;
  final String kind;
  final int count;
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

  static int _slotOverlapMs(String day, int slot, int ms, int startEpoch, int endEpoch) {
    final mid = DateTime.parse('${day}T00:00:00').millisecondsSinceEpoch ~/ 1000;
    final a = mid + slot * 300;
    final b = a + 300;
    final hi = math.min<int>(b, endEpoch);
    final lo = math.max<int>(a, startEpoch);
    final ov = hi - lo;
    if (ov <= 0) return 0;
    return ov >= 300 ? ms : (ms * ov / 300.0).round();
  }

  List<AppUsage> day(String day, {Set<String> devices = const {'local'}}) => range(day, day, devices: devices);

  List<AppUsage> range(String from, String to, {Set<String> devices = const {'local'}, int? startEpoch, int? endEpoch}) {
    final byDev = rangeByDevice(from, to, devices: devices, startEpoch: startEpoch, endEpoch: endEpoch);
    final map = <String, AppUsage>{};
    for (final entry in byDev) {
      final src = entry.usage;
      final u = map.putIfAbsent(src.app, () => AppUsage(src.app, src.name)..path = src.path);
      if (u.name.isEmpty && src.name.isNotEmpty) u.name = src.name;
      if (u.path.isEmpty && src.path.isNotEmpty) u.path = src.path;
      for (var i = 0; i < 4; i++) {
        u.ms[i] += src.ms[i];
      }
      u.devices.addAll(src.devices);
    }
    final list = map.values.where((a) => a.total > 0).toList();
    if (list.any((a) => a.visible > 0)) list.removeWhere((a) => a.visible == 0);
    list.sort((a, b) {
      final c = b.visible.compareTo(a.visible);
      return c != 0 ? c : b.total.compareTo(a.total);
    });
    return list;
  }

  List<DeviceAppUsage> rangeByDevice(String from, String to, {Set<String> devices = const {'local'}, int? startEpoch, int? endEpoch}) {
    final db = _open();
    if (db == null) return [];
    final out = <String, Map<String, AppUsage>>{};
    final localMeta = _hasLocal(devices) ? names(devices: const {'local'}) : const <String, AppMeta>{};
    final remoteMetaCache = <String, Map<String, AppMeta>>{};
    final sliced = startEpoch != null && endEpoch != null && endEpoch > startEpoch;

    AppMeta? metaFor(String dev, String app) {
      if (dev == 'local') return localMeta[app];
      final m = remoteMetaCache.putIfAbsent(dev, () => names(devices: {dev}));
      return m[app];
    }

    void addMs(String dev, String app, int state, int ms) {
      if (state < 0 || state > 3 || ms <= 0) return;
      final devMap = out.putIfAbsent(dev, () => {});
      final u = devMap.putIfAbsent(app, () {
        final m = metaFor(dev, app);
        return AppUsage(app, m?.name ?? '')
          ..path = m?.path ?? ''
          ..devices.add(dev);
      });
      u.ms[state] += ms;
    }

    try {
      if (_hasLocal(devices)) {
        if (!sliced) {
          for (final r in db.select('SELECT app, state, ms FROM usage WHERE day BETWEEN ? AND ?', [from, to])) {
            addMs('local', r['app'] as String, r['state'] as int, r['ms'] as int);
          }
        } else {
          int? minSessionStart;
          try {
            final r = db.select('SELECT MIN(start) AS m FROM sessions');
            if (r.isNotEmpty && r.first['m'] != null) minSessionStart = r.first['m'] as int;
          } catch (_) {}
          try {
            final lowest = startEpoch - sessionLowerSlack(db);
            for (final r in db.select('SELECT app, state, start, stop FROM sessions WHERE start >= ?3 AND start < ?2 AND stop > ?1', [startEpoch, endEpoch, lowest])) {
              final hi = math.min<int>(r['stop'] as int, endEpoch);
              final lo = math.max<int>(r['start'] as int, startEpoch);
              final ov = hi - lo;
              if (ov > 0) addMs('local', r['app'] as String, r['state'] as int, ov * 1000);
            }
          } catch (_) {}
          if (minSessionStart == null || startEpoch < minSessionStart) {
            try {
              final cutEnd = minSessionStart == null ? endEpoch : math.min(endEpoch, minSessionStart);
              for (final r in db.select('SELECT day, slot, app, state, ms FROM timeline WHERE day BETWEEN ? AND ?', [from, to])) {
                final ovMs = _slotOverlapMs(r['day'] as String, r['slot'] as int, r['ms'] as int, startEpoch, cutEnd);
                if (ovMs > 0) addMs('local', r['app'] as String, r['state'] as int, ovMs);
              }
            } catch (_) {}
          }
        }
      }
      final remotes = _remoteIds(devices);
      if (remotes.isNotEmpty) {
        final ph = List.filled(remotes.length, '?').join(',');
        if (!sliced) {
          try {
            for (final r in db.select('SELECT device, app, state, ms FROM remote_usage WHERE device IN ($ph) AND day BETWEEN ? AND ?', [...remotes, from, to])) {
              addMs(r['device'] as String, r['app'] as String, r['state'] as int, r['ms'] as int);
            }
          } catch (_) {}
        } else {
          try {
            for (final r in db.select('SELECT device, day, slot, app, state, ms FROM remote_timeline WHERE device IN ($ph) AND day BETWEEN ? AND ?', [...remotes, from, to])) {
              final ovMs = _slotOverlapMs(r['day'] as String, r['slot'] as int, r['ms'] as int, startEpoch, endEpoch);
              if (ovMs > 0) addMs(r['device'] as String, r['app'] as String, r['state'] as int, ovMs);
            }
          } catch (_) {}
        }
      }
    } catch (_) {
      return [];
    }
    final result = <DeviceAppUsage>[];
    out.forEach((dev, map) {
      final list = map.values.where((a) => a.total > 0).toList();
      if (list.any((a) => a.visible > 0)) list.removeWhere((a) => a.visible == 0);
      for (final u in list) {
        result.add(DeviceAppUsage(dev, u));
      }
    });
    result.sort((a, b) {
      final c = b.usage.visible.compareTo(a.usage.visible);
      if (c != 0) return c;
      final t = b.usage.total.compareTo(a.usage.total);
      return t != 0 ? t : a.device.compareTo(b.device);
    });
    return result;
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

  Map<String, List<SiteUsage>> browserSites(String from, String to, {Set<String> devices = const {'local'}, int? startEpoch, int? endEpoch}) {
    final byDev = browserSitesByDevice(from, to, devices: devices, startEpoch: startEpoch, endEpoch: endEpoch);
    final agg = <String, Map<String, ({int ms, String title, String url})>>{};
    byDev.forEach((_, browsers) {
      browsers.forEach((b, list) {
        final map = agg.putIfAbsent(b, () => {});
        for (final s in list) {
          final prev = map[s.domain];
          map[s.domain] = (
            ms: (prev?.ms ?? 0) + s.ms,
            title: s.title.isNotEmpty ? s.title : (prev?.title ?? ''),
            url: s.url.isNotEmpty ? s.url : (prev?.url ?? ''),
          );
        }
      });
    });
    final out = <String, List<SiteUsage>>{};
    agg.forEach((b, m) {
      final list = m.entries.map((e) => SiteUsage(b, e.key, e.value.ms, e.value.title, e.value.url)).toList()
        ..sort((a, b) => b.ms.compareTo(a.ms));
      out[b] = list;
    });
    return out;
  }

  Map<String, Map<String, List<SiteUsage>>> browserSitesByDevice(String from, String to, {Set<String> devices = const {'local'}, int? startEpoch, int? endEpoch}) {
    final db = _open();
    final out = <String, Map<String, List<SiteUsage>>>{};
    if (db == null) return out;
    final agg = <String, Map<String, Map<String, ({int ms, String title, String url})>>>{};
    final sliced = startEpoch != null && endEpoch != null && endEpoch > startEpoch;

    void feedAgg(String dev, String browser, String domain, int ms, String title, String url) {
      if (ms <= 0 || domain.isEmpty) return;
      final dMap = agg.putIfAbsent(dev, () => {});
      final bMap = dMap.putIfAbsent(browser.toLowerCase(), () => {});
      final prev = bMap[domain];
      final ct = cleanSiteTitle(title, domain);
      bMap[domain] = (
        ms: (prev?.ms ?? 0) + ms,
        title: ct.isNotEmpty ? ct : (prev?.title ?? ''),
        url: url.trim().isNotEmpty ? url.trim() : (prev?.url ?? ''),
      );
    }

    if (_hasLocal(devices)) {
      final urlCache = <String, ({String title, String url})>{};
      try {
        for (final r in db.select('SELECT browser, domain, title, url FROM browser_usage WHERE day BETWEEN ? AND ? ORDER BY day ASC', [from, to])) {
          final d = r['domain'] as String;
          final key = '${(r['browser'] as String).toLowerCase()}\u0000$d';
          final prev = urlCache[key];
          final t = cleanSiteTitle(r['title'] as String? ?? '', d);
          final u = (r['url'] as String? ?? '').trim();
          urlCache[key] = (
            title: t.isNotEmpty ? t : (prev?.title ?? ''),
            url: u.isNotEmpty ? u : (prev?.url ?? ''),
          );
        }
      } catch (_) {}
      if (!sliced) {
        try {
          for (final r in db.select('SELECT browser, domain, day, ms, title, url FROM browser_usage WHERE day BETWEEN ? AND ? ORDER BY day ASC', [from, to])) {
            feedAgg('local', r['browser'] as String, r['domain'] as String, r['ms'] as int, r['title'] as String? ?? '', r['url'] as String? ?? '');
          }
        } catch (_) {
          try {
            for (final r in db.select('SELECT browser, domain, SUM(ms) AS ms FROM browser_usage WHERE day BETWEEN ? AND ? GROUP BY browser, domain', [from, to])) {
              feedAgg('local', r['browser'] as String, r['domain'] as String, r['ms'] as int, '', '');
            }
          } catch (_) {}
        }
      } else {
        try {
          for (final r in db.select('SELECT day, slot, browser, domain, title, ms FROM browser_timeline WHERE day BETWEEN ? AND ? ORDER BY day ASC, slot ASC', [from, to])) {
            final ovMs = _slotOverlapMs(r['day'] as String, r['slot'] as int, r['ms'] as int, startEpoch, endEpoch);
            if (ovMs <= 0) continue;
            final b = (r['browser'] as String).toLowerCase();
            final d = r['domain'] as String;
            final meta = urlCache['$b\u0000$d'];
            final t = cleanSiteTitle(r['title'] as String? ?? '', d);
            feedAgg('local', b, d, ovMs, t.isNotEmpty ? t : (meta?.title ?? ''), meta?.url ?? '');
          }
        } catch (_) {}
      }
    }
    final remotes = _remoteIds(devices);
    if (remotes.isNotEmpty) {
      final ph = List.filled(remotes.length, '?').join(',');
      if (!sliced) {
        try {
          for (final r in db.select('SELECT device, browser, domain, ms, title, url FROM remote_browser_usage WHERE device IN ($ph) AND day BETWEEN ? AND ? ORDER BY day ASC', [...remotes, from, to])) {
            feedAgg(r['device'] as String, r['browser'] as String, r['domain'] as String, r['ms'] as int, r['title'] as String? ?? '', r['url'] as String? ?? '');
          }
        } catch (_) {
          try {
            for (final r in db.select('SELECT device, browser, domain, SUM(ms) AS ms FROM remote_browser_usage WHERE device IN ($ph) AND day BETWEEN ? AND ? GROUP BY device, browser, domain', [...remotes, from, to])) {
              feedAgg(r['device'] as String, r['browser'] as String, r['domain'] as String, r['ms'] as int, '', '');
            }
          } catch (_) {}
        }
      } else {
        final remoteUrlCache = <String, ({String title, String url})>{};
        try {
          for (final r in db.select('SELECT device, browser, domain, title, url FROM remote_browser_usage WHERE device IN ($ph) AND day BETWEEN ? AND ? ORDER BY day ASC', [...remotes, from, to])) {
            final d = r['domain'] as String;
            final key = '${r['device']}\u0000${(r['browser'] as String).toLowerCase()}\u0000$d';
            final t = cleanSiteTitle(r['title'] as String? ?? '', d);
            final u = (r['url'] as String? ?? '').trim();
            final prev = remoteUrlCache[key];
            remoteUrlCache[key] = (
              title: t.isNotEmpty ? t : (prev?.title ?? ''),
              url: u.isNotEmpty ? u : (prev?.url ?? ''),
            );
          }
        } catch (_) {}
        try {
          for (final r in db.select('SELECT device, day, slot, browser, domain, title, ms FROM remote_browser_timeline WHERE device IN ($ph) AND day BETWEEN ? AND ? ORDER BY day ASC, slot ASC', [...remotes, from, to])) {
            final ovMs = _slotOverlapMs(r['day'] as String, r['slot'] as int, r['ms'] as int, startEpoch, endEpoch);
            if (ovMs <= 0) continue;
            final dev = r['device'] as String;
            final b = (r['browser'] as String).toLowerCase();
            final d = r['domain'] as String;
            final meta = remoteUrlCache['$dev\u0000$b\u0000$d'];
            final t = cleanSiteTitle(r['title'] as String? ?? '', d);
            feedAgg(dev, b, d, ovMs, t.isNotEmpty ? t : (meta?.title ?? ''), meta?.url ?? '');
          }
        } catch (_) {}
      }
    }

    agg.forEach((dev, browsers) {
      final bOut = <String, List<SiteUsage>>{};
      browsers.forEach((b, m) {
        bOut[b] = m.entries.map((e) => SiteUsage(b, e.key, e.value.ms, e.value.title, e.value.url)).toList()
          ..sort((a, b) => b.ms.compareTo(a.ms));
      });
      out[dev] = bOut;
    });
    return out;
  }

  List<SessionRecord> sessionsRange(int startEpoch, int endEpoch, {Set<String> devices = const {'local'}}) {
    final db = _open();
    if (db == null || endEpoch <= startEpoch) return [];
    final out = <SessionRecord>[];
    if (_hasLocal(devices)) {
      try {
        final lowest = startEpoch - sessionLowerSlack(db);
        for (final r in db.select(
          'SELECT app, state, start, stop FROM sessions WHERE start >= ?3 AND start < ?2 AND stop > ?1 ORDER BY start ASC',
          [startEpoch, endEpoch, lowest],
        )) {
          final a = math.max(r['start'] as int, startEpoch);
          final b = math.min(r['stop'] as int, endEpoch);
          if (b > a) out.add(SessionRecord(r['app'] as String, r['state'] as int, a, b, 'local'));
        }
      } catch (_) {}
    }
    final remotes = _remoteIds(devices);
    if (remotes.isNotEmpty) {
      final aDt = DateTime.fromMillisecondsSinceEpoch(startEpoch * 1000);
      final bDt = DateTime.fromMillisecondsSinceEpoch((endEpoch - 1) * 1000);
      String dk(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      final ph = List.filled(remotes.length, '?').join(',');
      try {
        for (final r in db.select(
          'SELECT device, day, slot, app, state, ms FROM remote_timeline WHERE device IN ($ph) AND day BETWEEN ? AND ? ORDER BY device, day, slot, state, app',
          [...remotes, dk(aDt), dk(bDt)],
        )) {
          final ms = r['ms'] as int;
          if (ms <= 0) continue;
          final mid = DateTime.parse('${r['day']}T00:00:00').millisecondsSinceEpoch ~/ 1000;
          final s0 = mid + (r['slot'] as int) * 300;
          final dur = math.min(300, math.max(1, (ms / 1000).round()));
          final a = math.max(s0, startEpoch);
          final b = math.min(s0 + dur, endEpoch);
          if (b > a) out.add(SessionRecord(r['app'] as String, r['state'] as int, a, b, r['device'] as String));
        }
      } catch (_) {}
    }
    out.sort((a, b) => a.start.compareTo(b.start));
    return out;
  }

  ActivityStats activityStats(String from, String to, {Set<String> devices = const {'local'}, int? startEpoch, int? endEpoch}) {
    final db = _open();
    if (db == null) return const ActivityStats();
    var unlocks = 0;
    final opens = <String, int>{};
    final notifs = <String, int>{};
    final sliced = startEpoch != null && endEpoch != null && endEpoch > startEpoch;
    final hasLocal = _hasLocal(devices);
    final remotes = _remoteIds(devices);

    bool slotInside(String day, int slot) {
      if (!sliced) return true;
      final mid = DateTime.parse('${day}T00:00:00').millisecondsSinceEpoch ~/ 1000;
      final a = mid + slot * 300;
      return a + 300 > startEpoch && a < endEpoch;
    }

    if (hasLocal) {
      var gotSlotUnlocks = false;
      var gotSlotNotifs = false;
      if (sliced) {
        try {
          for (final r in db.select('SELECT day, slot, app, kind, n FROM slot_stats WHERE day BETWEEN ? AND ?', [from, to])) {
            final k = r['kind'] as String;
            if (k == 'unlocks') {
              gotSlotUnlocks = true;
              if (slotInside(r['day'] as String, r['slot'] as int)) unlocks += r['n'] as int;
            } else if (k == 'notifs') {
              gotSlotNotifs = true;
              if (slotInside(r['day'] as String, r['slot'] as int)) {
                final app = r['app'] as String;
                notifs[app] = (notifs[app] ?? 0) + (r['n'] as int);
              }
            }
          }
        } catch (_) {}
      }
      if (!gotSlotUnlocks) {
        try {
          for (final r in db.select("SELECT COALESCE(SUM(n), 0) AS n FROM day_stats WHERE kind = 'unlocks' AND day BETWEEN ? AND ?", [from, to])) {
            unlocks += (r['n'] as int?) ?? 0;
          }
        } catch (_) {}
      }
      if (!gotSlotNotifs) {
        try {
          for (final r in db.select("SELECT app, SUM(n) AS n FROM app_stats WHERE kind = 'notifs' AND day BETWEEN ? AND ? GROUP BY app", [from, to])) {
            notifs[r['app'] as String] = (notifs[r['app'] as String] ?? 0) + (r['n'] as int);
          }
        } catch (_) {}
      }
      var gotOpens = false;
      if (!sliced) {
        try {
          for (final r in db.select("SELECT app, SUM(n) AS n FROM app_stats WHERE kind = 'opens' AND day BETWEEN ? AND ? GROUP BY app", [from, to])) {
            opens[r['app'] as String] = (opens[r['app'] as String] ?? 0) + (r['n'] as int);
            gotOpens = true;
          }
        } catch (_) {}
      }
      if (!gotOpens) {
        try {
          final a = startEpoch ?? (DateTime.parse('${from}T00:00:00').millisecondsSinceEpoch ~/ 1000);
          final b = endEpoch ?? (DateTime.parse('${to}T00:00:00').add(const Duration(days: 1)).millisecondsSinceEpoch ~/ 1000);
          for (final r in db.select('SELECT app, COUNT(*) AS n FROM sessions WHERE state = 0 AND start >= ? AND start < ? GROUP BY app', [a, b])) {
            opens[r['app'] as String] = (opens[r['app'] as String] ?? 0) + (r['n'] as int);
            gotOpens = true;
          }
        } catch (_) {}
      }
      if (!gotOpens && sliced) {
        try {
          for (final r in db.select("SELECT day, slot, app, n FROM slot_stats WHERE kind = 'opens' AND day BETWEEN ? AND ?", [from, to])) {
            if (slotInside(r['day'] as String, r['slot'] as int)) {
              final app = r['app'] as String;
              opens[app] = (opens[app] ?? 0) + (r['n'] as int);
            }
          }
        } catch (_) {}
      }
    }
    if (remotes.isNotEmpty) {
      final ph = List.filled(remotes.length, '?').join(',');
      var gotRemoteSlots = false;
      if (sliced) {
        try {
          for (final r in db.select('SELECT day, slot, app, kind, n FROM remote_slot_stats WHERE device IN ($ph) AND day BETWEEN ? AND ?', [...remotes, from, to])) {
            gotRemoteSlots = true;
            if (!slotInside(r['day'] as String, r['slot'] as int)) continue;
            final k = r['kind'] as String;
            final n = r['n'] as int;
            if (k == 'unlocks') {
              unlocks += n;
            } else if (k == 'notifs') {
              final app = r['app'] as String;
              notifs[app] = (notifs[app] ?? 0) + n;
            } else if (k == 'opens') {
              final app = r['app'] as String;
              opens[app] = (opens[app] ?? 0) + n;
            }
          }
        } catch (_) {}
      }
      if (!gotRemoteSlots) {
        try {
          for (final r in db.select("SELECT COALESCE(SUM(n), 0) AS n FROM remote_day_stats WHERE device IN ($ph) AND kind = 'unlocks' AND day BETWEEN ? AND ?", [...remotes, from, to])) {
            unlocks += (r['n'] as int?) ?? 0;
          }
        } catch (_) {}
        try {
          for (final r in db.select("SELECT app, kind, SUM(n) AS n FROM remote_app_stats WHERE device IN ($ph) AND day BETWEEN ? AND ? GROUP BY app, kind", [...remotes, from, to])) {
            final app = r['app'] as String;
            final n = r['n'] as int;
            if (r['kind'] == 'notifs') {
              notifs[app] = (notifs[app] ?? 0) + n;
            } else if (r['kind'] == 'opens') {
              opens[app] = (opens[app] ?? 0) + n;
            }
          }
        } catch (_) {}
      }
    }
    return ActivityStats(unlocks: unlocks, opens: opens, notifs: notifs);
  }

  List<StatPoint> statPoints(DateTime first, int w0, int w1, int bin, {Set<String> devices = const {'local'}, int? startEpoch, int? endEpoch}) {
    final db = _open();
    if (db == null) return [];
    final a = first.add(Duration(seconds: w0));
    final b = first.add(Duration(seconds: w1));
    String key(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    final ka = key(a);
    final kb = key(b);
    final step = bin * 300;
    final firstUnix = first.millisecondsSinceEpoch ~/ 1000;
    final sliced = startEpoch != null && endEpoch != null && endEpoch > startEpoch;
    final clipA = sliced ? startEpoch - firstUnix : null;
    final clipB = sliced ? endEpoch - firstUnix : null;
    final agg = <String, int>{};

    void addCount(int start, int end, String app, String kind, int n) {
      if (n <= 0) return;
      if (clipA != null && clipB != null) {
        if (end <= clipA || start >= clipB) return;
      }
      final k = '$start\u0000$end\u0000$kind\u0000$app';
      agg[k] = (agg[k] ?? 0) + n;
    }

    if (_hasLocal(devices)) {
      var hasSlotOpens = false;
      try {
        for (final r in db.select(
          'SELECT day, (slot / ?3) * ?3 AS bslot, app, kind, SUM(n) AS n FROM slot_stats WHERE day BETWEEN ?1 AND ?2 GROUP BY day, slot / ?3, app, kind',
          [ka, kb, bin],
        )) {
          final kind = r['kind'] as String;
          if (kind == 'opens') hasSlotOpens = true;
          final midnight = DateTime.parse('${r['day']}T00:00:00');
          final start = midnight.add(Duration(seconds: (r['bslot'] as int) * 300)).difference(first).inSeconds;
          addCount(start, start + step, r['app'] as String, kind, r['n'] as int);
        }
      } catch (_) {}
      if (!hasSlotOpens) {
        try {
          final lo = sliced ? math.max(firstUnix + w0, startEpoch) : firstUnix + w0;
          final hi = sliced ? math.min(firstUnix + w1, endEpoch) : firstUnix + w1;
          for (final r in db.select('SELECT app, start FROM sessions WHERE state = 0 AND start >= ?1 AND start < ?2', [lo, hi])) {
            final sec = (r['start'] as int) - firstUnix;
            final bStart = (sec ~/ step) * step;
            addCount(bStart, bStart + step, r['app'] as String, 'opens', 1);
          }
        } catch (_) {}
      }
      try {
        final lo = sliced ? math.max(firstUnix + w0, startEpoch) : firstUnix + w0;
        final hi = sliced ? math.min(firstUnix + w1, endEpoch) : firstUnix + w1;
        for (final r in db.select('SELECT ts, kind, duration_ms FROM sys_events WHERE ts >= ?1 AND ts < ?2', [lo, hi])) {
          final k = r['kind'] as String;
          final dur = r['duration_ms'] as int;
          final sec = (r['ts'] as int) - firstUnix;
          final bStart = (sec ~/ step) * step;
          final isDur = k == 'sleep' || k == 'hibernate' || k == 'lock';
          final val = isDur ? dur : 1;
          if (val > 0) addCount(bStart, bStart + step, '', 'power_$k', val);
        }
      } catch (_) {}
    }

    final remotes = _remoteIds(devices);
    if (remotes.isNotEmpty) {
      final ph = List.generate(remotes.length, (i) => '?${4 + i}').join(',');
      try {
        for (final r in db.select(
          'SELECT day, (slot / ?3) * ?3 AS bslot, app, kind, SUM(n) AS n FROM remote_slot_stats WHERE day BETWEEN ?1 AND ?2 AND device IN ($ph) GROUP BY day, slot / ?3, app, kind',
          [ka, kb, bin, ...remotes],
        )) {
          final midnight = DateTime.parse('${r['day']}T00:00:00');
          final start = midnight.add(Duration(seconds: (r['bslot'] as int) * 300)).difference(first).inSeconds;
          addCount(start, start + step, r['app'] as String, r['kind'] as String, r['n'] as int);
        }
      } catch (_) {}
      try {
        final lo = sliced ? math.max(firstUnix + w0, startEpoch) : firstUnix + w0;
        final hi = sliced ? math.min(firstUnix + w1, endEpoch) : firstUnix + w1;
        final phSys = List.generate(remotes.length, (i) => '?${3 + i}').join(',');
        for (final r in db.select('SELECT ts, kind, duration_ms FROM remote_sys_events WHERE ts >= ?1 AND ts < ?2 AND device IN ($phSys)', [lo, hi, ...remotes])) {
          final k = r['kind'] as String;
          final dur = r['duration_ms'] as int;
          final sec = (r['ts'] as int) - firstUnix;
          final bStart = (sec ~/ step) * step;
          final isDur = k == 'sleep' || k == 'hibernate' || k == 'lock';
          final val = isDur ? dur : 1;
          if (val > 0) addCount(bStart, bStart + step, '', 'power_$k', val);
        }
      } catch (_) {}
    }

    final out = <StatPoint>[];
    agg.forEach((k, n) {
      final p1 = k.indexOf('\u0000');
      final p2 = k.indexOf('\u0000', p1 + 1);
      final p3 = k.indexOf('\u0000', p2 + 1);
      out.add(StatPoint(
        int.parse(k.substring(0, p1)),
        int.parse(k.substring(p1 + 1, p2)),
        k.substring(p3 + 1),
        k.substring(p2 + 1, p3),
        n,
      ));
    });
    return out;
  }

  List<SiteContrib> browserContribs(DateTime first, int w0, int w1, int bin, {Set<String> devices = const {'local'}, int? startEpoch, int? endEpoch}) {
    final db = _open();
    if (db == null) return [];
    final agg = <String, ({int ms, String title})>{};
    final a = first.add(Duration(seconds: w0));
    final b = first.add(Duration(seconds: w1));
    String key(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    final ka = key(a);
    final kb = key(b);
    final sliced = startEpoch != null && endEpoch != null && endEpoch > startEpoch;
    final firstUnix = first.millisecondsSinceEpoch ~/ 1000;
    final clipA = sliced ? startEpoch - firstUnix : null;
    final clipB = sliced ? endEpoch - firstUnix : null;

    void feed(Iterable<Row> rows) {
      for (final r in rows) {
        var ms = r['ms'] as int;
        if (ms <= 0) continue;
        final midnight = DateTime.parse('${r['day']}T00:00:00');
        final bslot = ((r['slot'] as int) ~/ bin) * bin;
        var start = midnight.add(Duration(seconds: bslot * 300)).difference(first).inSeconds;
        var end = start + bin * 300;
        if (clipA != null && clipB != null) {
          final ca = math.max(start, clipA);
          final cb = math.min(end, clipB);
          if (cb <= ca) continue;
          if (cb - ca < end - start) ms = (ms * (cb - ca) / (end - start)).round();
          if (ms <= 0) continue;
          start = ca;
          end = cb;
        }
        final br = (r['browser'] as String).toLowerCase();
        final dom = r['domain'] as String;
        final ct = cleanSiteTitle(r['title'] as String? ?? '', dom);
        final k = '$start\u0000$end\u0000$br\u0000$dom';
        final prev = agg[k];
        agg[k] = (
          ms: (prev?.ms ?? 0) + ms,
          title: ct.isNotEmpty ? ct : (prev?.title ?? ''),
        );
      }
    }

    if (_hasLocal(devices)) {
      try {
        feed(db.select(
          'SELECT day, slot, browser, domain, title, ms FROM browser_timeline WHERE day BETWEEN ?1 AND ?2 ORDER BY day ASC, slot ASC',
          [ka, kb],
        ));
      } catch (_) {}
    }
    final remotes = _remoteIds(devices);
    if (remotes.isNotEmpty) {
      try {
        final ph = List.generate(remotes.length, (i) => '?${3 + i}').join(',');
        feed(db.select(
          'SELECT day, slot, browser, domain, title, ms FROM remote_browser_timeline WHERE day BETWEEN ?1 AND ?2 AND device IN ($ph) ORDER BY day ASC, slot ASC',
          [ka, kb, ...remotes],
        ));
      } catch (_) {}
    }
    final out = <SiteContrib>[];
    agg.forEach((k, v) {
      final p1 = k.indexOf('\u0000');
      final p2 = k.indexOf('\u0000', p1 + 1);
      final p3 = k.indexOf('\u0000', p2 + 1);
      out.add(SiteContrib(
        int.parse(k.substring(0, p1)),
        int.parse(k.substring(p1 + 1, p2)),
        k.substring(p2 + 1, p3),
        k.substring(p3 + 1),
        v.title,
        v.ms,
      ));
    });
    return out;
  }

  Map<String, int> afk(String from, String to, {Set<String> devices = const {'local'}}) {
    final db = _open();
    final out = <String, int>{};
    if (db == null) return out;
    if (_hasLocal(devices)) {
      try {
        for (final r in db.select('SELECT app, SUM(ms) AS ms FROM afk WHERE day BETWEEN ? AND ? GROUP BY app', [from, to])) {
          final app = r['app'] as String;
          out[app] = (out[app] ?? 0) + (r['ms'] as int);
        }
      } catch (_) {}
    }
    final remotes = _remoteIds(devices);
    if (remotes.isNotEmpty) {
      try {
        final ph = List.filled(remotes.length, '?').join(',');
        for (final r in db.select('SELECT app, SUM(ms) AS ms FROM remote_afk WHERE device IN ($ph) AND day BETWEEN ? AND ? GROUP BY app', [...remotes, from, to])) {
          final app = r['app'] as String;
          out[app] = (out[app] ?? 0) + (r['ms'] as int);
        }
      } catch (_) {}
    }
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

  List<Contrib> contribs(DateTime first, int w0, int w1, int bin, bool sessions, {bool realFocus = false, Set<String> devices = const {'local'}, int? startEpoch, int? endEpoch}) {
    final db = _open();
    if (db == null) return [];
    final out = <Contrib>[];
    if (realFocus) sessions = false;
    final hasLocal = _hasLocal(devices);
    final remotes = _remoteIds(devices);
    final firstUnix = first.millisecondsSinceEpoch ~/ 1000;
    final sliced = startEpoch != null && endEpoch != null && endEpoch > startEpoch;
    final clipA = sliced ? startEpoch - firstUnix : null;
    final clipB = sliced ? endEpoch - firstUnix : null;
    int? cutoff;
    if (sessions && hasLocal) {
      try {
        final r = db.select('SELECT MIN(start) AS m FROM sessions');
        if (r.isNotEmpty && r.first['m'] != null) cutoff = (r.first['m'] as int) - firstUnix;
      } catch (_) {}
    }
    void pushClipped(int start, int end, String app, int state, int ms) {
      if (clipA != null && clipB != null) {
        final ca = math.max<int>(start, clipA);
        final cb = math.min<int>(end, clipB);
        if (cb <= ca) return;
        final dur = end - start;
        final scaled = dur > 0 && cb - ca < dur ? (ms * (cb - ca) / dur).round() : ms;
        if (scaled <= 0) return;
        out.add(Contrib(ca, cb, app, state, scaled));
      } else {
        out.add(Contrib(start, end, app, state, ms));
      }
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
          pushClipped(start, end, r['app'] as String, r['state'] as int, ms);
        }
      }
      if (remotes.isNotEmpty) {
        try {
          final ka = key(a);
          final kb = key(b);
          final ph = List.generate(remotes.length, (i) => '?${4 + i}').join(',');
          final remoteIdle = <String, int>{};
          if (realFocus) {
            try {
              for (final r in db.select(
                'SELECT device, day, (slot / ?3) * ?3 AS bslot, app, SUM(ms) AS ms FROM remote_afk WHERE day BETWEEN ?1 AND ?2 AND device IN ($ph) GROUP BY device, day, slot / ?3, app',
                [ka, kb, bin, ...remotes],
              )) {
                remoteIdle['${r['device']}|${r['day']}|${r['bslot']}|${r['app']}'] = r['ms'] as int;
              }
            } catch (_) {}
          }
          final rows = db.select(
              'SELECT device, day, (slot / ?3) * ?3 AS bslot, app, state, SUM(ms) AS ms FROM remote_timeline WHERE day BETWEEN ?1 AND ?2 AND device IN ($ph) GROUP BY device, day, slot / ?3, app, state',
              [ka, kb, bin, ...remotes]);
          for (final r in rows) {
            final midnight = DateTime.parse('${r['day']}T00:00:00');
            final start = midnight.add(Duration(seconds: (r['bslot'] as int) * 300)).difference(first).inSeconds;
            final end = start + bin * 300;
            var ms = r['ms'] as int;
            if (realFocus && r['state'] == 0) {
              ms = math.max(0, ms - (remoteIdle['${r['device']}|${r['day']}|${r['bslot']}|${r['app']}'] ?? 0));
            }
            if (ms == 0) continue;
            pushClipped(start, end, r['app'] as String, r['state'] as int, ms);
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
          pushClipped(start, end, r['app'] as String, r['state'] as int, (end - start) * 1000);
        }
      } catch (_) {}
    }
    return out;
  }

  Map<String, ResAgg> resources(String from, String to, {Set<String> devices = const {'local'}}) {
    final db = _open();
    final out = <String, ResAgg>{};
    if (db == null) return out;
    void mergeRow(Row r) {
      final app = r['app'] as String;
      final cur = out.putIfAbsent(app, ResAgg.new);
      cur.cpuMs += r['cpu'] as int;
      cur.ramSum += r['ram'] as int;
      cur.ramN += r['n'] as int;
      final pk = r['peak'] as int;
      if (pk > cur.peakKb) cur.peakKb = pk;
      cur.ior += r['ior'] as int;
      cur.iow += r['iow'] as int;
    }

    if (_hasLocal(devices)) {
      try {
        for (final r in db.select('SELECT app, SUM(cpu) AS cpu, SUM(ram) AS ram, SUM(n) AS n, MAX(peak) AS peak, SUM(ior) AS ior, SUM(iow) AS iow FROM res WHERE day BETWEEN ? AND ? GROUP BY app', [from, to])) {
          mergeRow(r);
        }
      } catch (_) {}
    }
    final remotes = _remoteIds(devices);
    if (remotes.isNotEmpty) {
      try {
        final ph = List.filled(remotes.length, '?').join(',');
        for (final r in db.select('SELECT app, SUM(cpu) AS cpu, SUM(ram) AS ram, SUM(n) AS n, MAX(peak) AS peak, SUM(ior) AS ior, SUM(iow) AS iow FROM remote_res WHERE device IN ($ph) AND day BETWEEN ? AND ? GROUP BY app', [...remotes, from, to])) {
          mergeRow(r);
        }
      } catch (_) {}
    }
    return out;
  }

  List<ResPoint> resPoints(DateTime first, int w0, int w1, int bin, {Set<String> devices = const {'local'}, int? startEpoch, int? endEpoch}) {
    final db = _open();
    if (db == null) return [];
    final a = first.add(Duration(seconds: w0));
    final b = first.add(Duration(seconds: w1));
    String key(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    final ka = key(a);
    final kb = key(b);
    final sliced = startEpoch != null && endEpoch != null && endEpoch > startEpoch;
    final firstUnix = first.millisecondsSinceEpoch ~/ 1000;
    final clipA = sliced ? startEpoch - firstUnix : null;
    final clipB = sliced ? endEpoch - firstUnix : null;
    final agg = <String, ({int start, int end, String app, int cpu, int ram, int n, int peak, int ior, int iow})>{};

    void feed(Iterable<Row> rows) {
      for (final r in rows) {
        final midnight = DateTime.parse('${r['day']}T00:00:00');
        final start = midnight.add(Duration(seconds: (r['bslot'] as int) * 300)).difference(first).inSeconds;
        final end = start + bin * 300;
        if (clipA != null && clipB != null && (end <= clipA || start >= clipB)) continue;
        final app = r['app'] as String;
        final k = '$start\u0000$app';
        final prev = agg[k];
        final peak = r['peak'] as int;
        agg[k] = (
          start: start,
          end: end,
          app: app,
          cpu: (prev?.cpu ?? 0) + (r['cpu'] as int),
          ram: (prev?.ram ?? 0) + (r['ram'] as int),
          n: (prev?.n ?? 0) + (r['n'] as int),
          peak: prev == null ? peak : math.max(prev.peak, peak),
          ior: (prev?.ior ?? 0) + (r['ior'] as int),
          iow: (prev?.iow ?? 0) + (r['iow'] as int),
        );
      }
    }

    if (_hasLocal(devices)) {
      try {
        feed(db.select(
            'SELECT day, (slot / ?3) * ?3 AS bslot, app, SUM(cpu) AS cpu, SUM(ram) AS ram, SUM(n) AS n, MAX(peak) AS peak, SUM(ior) AS ior, SUM(iow) AS iow FROM res WHERE day BETWEEN ?1 AND ?2 GROUP BY day, slot / ?3, app',
            [ka, kb, bin]));
      } catch (_) {}
    }
    final remotes = _remoteIds(devices);
    if (remotes.isNotEmpty) {
      try {
        final ph = List.generate(remotes.length, (i) => '?${4 + i}').join(',');
        feed(db.select(
            'SELECT day, (slot / ?3) * ?3 AS bslot, app, SUM(cpu) AS cpu, SUM(ram) AS ram, SUM(n) AS n, MAX(peak) AS peak, SUM(ior) AS ior, SUM(iow) AS iow FROM remote_res WHERE day BETWEEN ?1 AND ?2 AND device IN ($ph) GROUP BY day, slot / ?3, app',
            [ka, kb, bin, ...remotes]));
      } catch (_) {}
    }
    return [
      for (final v in agg.values)
        ResPoint(v.start, v.end, v.app, v.cpu, v.n == 0 ? 0 : v.ram ~/ v.n, v.peak, v.ior, v.iow),
    ];
  }

  List<SysPoint> sysPoints(DateTime first, int w0, int w1, {Set<String> devices = const {'local'}, int? startEpoch, int? endEpoch}) {
    final db = _open();
    if (db == null) return [];
    final firstUnix = first.millisecondsSinceEpoch ~/ 1000;
    final sliced = startEpoch != null && endEpoch != null && endEpoch > startEpoch;
    final lo = sliced ? math.max(firstUnix + w0, startEpoch) : firstUnix + w0;
    final hi = sliced ? math.min(firstUnix + w1, endEpoch) : firstUnix + w1;
    final out = <SysPoint>[];
    if (_hasLocal(devices)) {
      try {
        for (final r in db.select('SELECT ts, kind, a, b FROM sysmon WHERE ts >= ?1 AND ts <= ?2 ORDER BY ts', [lo, hi])) {
          out.add(SysPoint((r['ts'] as int) - firstUnix, r['kind'] as String, r['a'] as int, r['b'] as int, 'local'));
        }
      } catch (_) {}
    }
    final remotes = _remoteIds(devices);
    if (remotes.isNotEmpty) {
      try {
        final ph = List.generate(remotes.length, (i) => '?${3 + i}').join(',');
        for (final r in db.select('SELECT device, ts, kind, a, b FROM remote_sysmon WHERE ts >= ?1 AND ts <= ?2 AND device IN ($ph) ORDER BY ts', [lo, hi, ...remotes])) {
          out.add(SysPoint((r['ts'] as int) - firstUnix, r['kind'] as String, r['a'] as int, r['b'] as int, r['device'] as String));
        }
      } catch (_) {}
    }
    out.sort((a, b) => a.t.compareTo(b.t));
    return out;
  }

  List<GlobalDeviceStats> globalStats(
    String from,
    String to, {
    Set<String> devices = const {'local'},
    int? startEpoch,
    int? endEpoch,
    String localName = '',
    String localPlatform = '',
  }) {
    final db = _open();
    if (db == null) return const [];
    final sliced = startEpoch != null && endEpoch != null && endEpoch > startEpoch;
    final epStart = startEpoch ?? (DateTime.parse('${from}T00:00:00').millisecondsSinceEpoch ~/ 1000);
    final epEnd = endEpoch ?? (DateTime.parse('${to}T00:00:00').add(const Duration(days: 1)).millisecondsSinceEpoch ~/ 1000);
    final devMeta = <String, ({String name, String platform})>{};
    for (final d in this.devices()) {
      devMeta[d.id] = (name: d.name, platform: d.platform);
    }
    final order = <String>[
      if (_hasLocal(devices)) 'local',
      ..._remoteIds(devices),
    ];
    final map = <String, GlobalDeviceStats>{};
    for (final id in order) {
      final meta = devMeta[id];
      final name = id == 'local' ? (localName.isNotEmpty ? localName : tr('thisDevice')) : (meta?.name ?? id);
      final plat = id == 'local' ? localPlatform : (meta?.platform ?? '');
      map[id] = GlobalDeviceStats(id, name, plat);
    }

    for (final dRow in rangeByDevice(from, to, devices: devices, startEpoch: startEpoch, endEpoch: endEpoch)) {
      final gs = map[dRow.device];
      if (gs == null) continue;
      gs.focusedMs += dRow.usage.ms[0];
      gs.visibleMs += dRow.usage.visible;
      gs.totalMs += dRow.usage.total;
    }

    if (map.containsKey('local')) {
      final gs = map['local']!;
      try {
        for (final r in db.select('SELECT SUM(ms) AS ms FROM afk WHERE day BETWEEN ? AND ?', [from, to])) {
          gs.afkMs += (r['ms'] as int?) ?? 0;
        }
      } catch (_) {}
      final st = activityStats(from, to, devices: const {'local'}, startEpoch: startEpoch, endEpoch: endEpoch);
      gs.unlocks += st.unlocks;
      for (final n in st.opens.values) {
        gs.opens += n;
      }
      for (final n in st.notifs.values) {
        gs.notifs += n;
      }
      try {
        for (final r in db.select('SELECT kind, duration_ms FROM sys_events WHERE ts >= ?1 AND ts < ?2', [epStart, epEnd])) {
          final k = r['kind'] as String;
          final p = gs.power.putIfAbsent(k, GlobalPowerRow.new);
          p.count++;
          p.durationMs += r['duration_ms'] as int;
        }
      } catch (_) {}
      void fillLocalSys(Iterable<Row> rows) {
        final seen = <String>{};
        for (final r in rows) {
          final k = r['kind'] as String;
          if (!seen.add(k)) continue;
          final a = r['a'] as int;
          final b = r['b'] as int;
          if (k == 'ram') {
            gs.ramTotalKb = a;
            gs.ramFreeKb = b;
          } else if (k.startsWith('disk:')) {
            gs.disks.add(GlobalDiskRow(k.substring(5), a, b));
          }
        }
      }
      try {
        var rows = db.select('SELECT kind, a, b FROM sysmon WHERE ts < ?1 ORDER BY ts DESC', [epEnd]);
        if (rows.isEmpty && !sliced) {
          rows = db.select('SELECT kind, a, b FROM sysmon ORDER BY ts DESC');
        }
        fillLocalSys(rows);
      } catch (_) {}
      gs.disks.sort((a, b) => a.mount.compareTo(b.mount));
    }

    for (final id in _remoteIds(devices)) {
      final gs = map[id];
      if (gs == null) continue;
      try {
        for (final r in db.select('SELECT SUM(ms) AS ms FROM remote_afk WHERE device = ? AND day BETWEEN ? AND ?', [id, from, to])) {
          gs.afkMs += (r['ms'] as int?) ?? 0;
        }
      } catch (_) {}
      final st = activityStats(from, to, devices: {id}, startEpoch: startEpoch, endEpoch: endEpoch);
      gs.unlocks += st.unlocks;
      for (final n in st.opens.values) {
        gs.opens += n;
      }
      for (final n in st.notifs.values) {
        gs.notifs += n;
      }
      try {
        for (final r in db.select('SELECT kind, duration_ms FROM remote_sys_events WHERE device = ? AND ts >= ? AND ts < ?', [id, epStart, epEnd])) {
          final k = r['kind'] as String;
          final p = gs.power.putIfAbsent(k, GlobalPowerRow.new);
          p.count++;
          p.durationMs += r['duration_ms'] as int;
        }
      } catch (_) {}
      void fillRemoteSys(Iterable<Row> rows) {
        final seen = <String>{};
        for (final r in rows) {
          final k = r['kind'] as String;
          if (!seen.add(k)) continue;
          final a = r['a'] as int;
          final b = r['b'] as int;
          if (k == 'ram') {
            gs.ramTotalKb = a;
            gs.ramFreeKb = b;
          } else if (k.startsWith('disk:')) {
            gs.disks.add(GlobalDiskRow(k.substring(5), a, b));
          }
        }
      }
      try {
        var rows = db.select('SELECT kind, a, b FROM remote_sysmon WHERE device = ? AND ts < ? ORDER BY ts DESC', [id, epEnd]);
        if (rows.isEmpty && !sliced) {
          rows = db.select('SELECT kind, a, b FROM remote_sysmon WHERE device = ? ORDER BY ts DESC', [id]);
        }
        fillRemoteSys(rows);
      } catch (_) {}
      gs.disks.sort((a, b) => a.mount.compareTo(b.mount));
    }

    return [for (final id in order) map[id]!];
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
