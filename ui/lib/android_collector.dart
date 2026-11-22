import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:sqlite3/sqlite3.dart';
import 'data.dart';

const evResumed = 1;
const evPaused = 2;
const evNotif = 12;
const evScreenOff = 16;
const evUnlock = 18;
const evShutdown = 26;

class UsageEvent {
  const UsageEvent(this.pkg, this.type, this.ms);

  final String pkg;
  final int type;
  final int ms;
}

class SessionSpan {
  const SessionSpan(this.app, this.start, this.stop);

  final String app;
  final int start;
  final int stop;
}

List<SessionSpan> buildSessions(List<UsageEvent> events, int nowMs) {
  final sorted = [...events]..sort((a, b) => a.ms.compareTo(b.ms));
  final out = <SessionSpan>[];
  String? app;
  int started = 0;

  void close(int at) {
    if (app != null && at - started >= 1000) out.add(SessionSpan(app!, started ~/ 1000, at ~/ 1000));
    app = null;
  }

  for (final e in sorted) {
    switch (e.type) {
      case evResumed:
        if (app == e.pkg) continue;
        close(e.ms);
        app = e.pkg;
        started = e.ms;
      case evPaused:
        if (app == e.pkg) close(e.ms);
      case evScreenOff:
      case evShutdown:
        close(e.ms);
    }
  }
  close(nowMs);
  return out;
}

class DayTotals {
  final Map<String, int> usage = {};
  final Map<String, int> timeline = {};

  static String key(int slot, String app) => '$slot\u0000$app';
}

String dayKey(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

DayTotals aggregateDay(List<SessionSpan> sessions, DateTime dayStart) {
  final t = DayTotals();
  final dayEnd = DateTime(dayStart.year, dayStart.month, dayStart.day + 1);
  final a = dayStart.millisecondsSinceEpoch;
  final b = dayEnd.millisecondsSinceEpoch;
  for (final s in sessions) {
    var from = s.start * 1000;
    final to = (s.stop * 1000) < b ? s.stop * 1000 : b;
    if (from < a) from = a;
    if (to <= from) continue;
    t.usage[s.app] = (t.usage[s.app] ?? 0) + (to - from);
    var cursor = from;
    while (cursor < to) {
      final slot = (cursor - a) ~/ 300000;
      final slotEnd = a + (slot + 1) * 300000;
      final upTo = to < slotEnd ? to : slotEnd;
      final k = DayTotals.key(slot, s.app);
      t.timeline[k] = (t.timeline[k] ?? 0) + (upTo - cursor);
      cursor = upTo;
    }
  }
  return t;
}

const _schema = '''
PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;
CREATE TABLE IF NOT EXISTS usage(day TEXT NOT NULL, app TEXT NOT NULL, state INTEGER NOT NULL, ms INTEGER NOT NULL, PRIMARY KEY(day, app, state)) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS timeline(day TEXT NOT NULL, slot INTEGER NOT NULL, app TEXT NOT NULL, state INTEGER NOT NULL, ms INTEGER NOT NULL, PRIMARY KEY(day, slot, app, state)) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS sessions(app TEXT NOT NULL, start INTEGER NOT NULL, stop INTEGER NOT NULL, state INTEGER NOT NULL, PRIMARY KEY(app, start)) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS sessions_start ON sessions(start);
CREATE TABLE IF NOT EXISTS presence(ts INTEGER NOT NULL, client_id TEXT NOT NULL, name TEXT NOT NULL, details TEXT NOT NULL, state TEXT NOT NULL, started INTEGER NOT NULL, raw TEXT NOT NULL DEFAULT '');
CREATE TABLE IF NOT EXISTS apps(app TEXT PRIMARY KEY, name TEXT NOT NULL, path TEXT NOT NULL DEFAULT '') WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS browser_usage(day TEXT NOT NULL, browser TEXT NOT NULL, domain TEXT NOT NULL, ms INTEGER NOT NULL, title TEXT NOT NULL DEFAULT '', url TEXT NOT NULL DEFAULT '', PRIMARY KEY(day, browser, domain)) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS browser_timeline(day TEXT NOT NULL, slot INTEGER NOT NULL, browser TEXT NOT NULL, domain TEXT NOT NULL, title TEXT NOT NULL DEFAULT '', ms INTEGER NOT NULL, PRIMARY KEY(day, slot, browser, domain)) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS devices(id TEXT PRIMARY KEY, name TEXT NOT NULL, platform TEXT NOT NULL, host TEXT NOT NULL DEFAULT '', port INTEGER NOT NULL DEFAULT 9096, last_sync INTEGER NOT NULL DEFAULT 0) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS remote_usage(device TEXT NOT NULL, day TEXT NOT NULL, app TEXT NOT NULL, state INTEGER NOT NULL, ms INTEGER NOT NULL, PRIMARY KEY(device, day, app, state)) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS remote_timeline(device TEXT NOT NULL, day TEXT NOT NULL, slot INTEGER NOT NULL, app TEXT NOT NULL, state INTEGER NOT NULL, ms INTEGER NOT NULL, PRIMARY KEY(device, day, slot, app, state)) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS remote_apps(device TEXT NOT NULL, app TEXT NOT NULL, name TEXT NOT NULL, path TEXT NOT NULL DEFAULT '', PRIMARY KEY(device, app)) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS remote_browser_usage(device TEXT NOT NULL, day TEXT NOT NULL, browser TEXT NOT NULL, domain TEXT NOT NULL, ms INTEGER NOT NULL, title TEXT NOT NULL DEFAULT '', url TEXT NOT NULL DEFAULT '', PRIMARY KEY(device, day, browser, domain)) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS remote_browser_timeline(device TEXT NOT NULL, day TEXT NOT NULL, slot INTEGER NOT NULL, browser TEXT NOT NULL, domain TEXT NOT NULL, title TEXT NOT NULL DEFAULT '', ms INTEGER NOT NULL, PRIMARY KEY(device, day, slot, browser, domain)) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS day_stats(day TEXT NOT NULL, kind TEXT NOT NULL, n INTEGER NOT NULL, PRIMARY KEY(day, kind)) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS app_stats(day TEXT NOT NULL, app TEXT NOT NULL, kind TEXT NOT NULL, n INTEGER NOT NULL, PRIMARY KEY(day, app, kind)) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS slot_stats(day TEXT NOT NULL, slot INTEGER NOT NULL, app TEXT NOT NULL, kind TEXT NOT NULL, n INTEGER NOT NULL, PRIMARY KEY(day, slot, app, kind)) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS remote_day_stats(device TEXT NOT NULL, day TEXT NOT NULL, kind TEXT NOT NULL, n INTEGER NOT NULL, PRIMARY KEY(device, day, kind)) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS remote_app_stats(device TEXT NOT NULL, day TEXT NOT NULL, app TEXT NOT NULL, kind TEXT NOT NULL, n INTEGER NOT NULL, PRIMARY KEY(device, day, app, kind)) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS remote_slot_stats(device TEXT NOT NULL, day TEXT NOT NULL, slot INTEGER NOT NULL, app TEXT NOT NULL, kind TEXT NOT NULL, n INTEGER NOT NULL, PRIMARY KEY(device, day, slot, app, kind)) WITHOUT ROWID;
''';

int _maxSpan = -1;
int _maxSpanAt = 0;

int sessionSlack(Database db, List<SessionSpan> fresh) {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  if (_maxSpan < 0 || now - _maxSpanAt > 600) {
    try {
      final r = db.select('SELECT MAX(stop - start) AS m FROM sessions');
      _maxSpan = r.isNotEmpty && r.first['m'] != null ? r.first['m'] as int : 0;
    } catch (_) {
      _maxSpan = 0;
    }
    _maxSpanAt = now;
  }
  for (final s in fresh) {
    if (s.stop - s.start > _maxSpan) _maxSpan = s.stop - s.start;
  }
  return _maxSpan + (now - _maxSpanAt) + 60;
}

void storeSessions(Database db, List<SessionSpan> sessions, DateTime firstDay, DateTime lastDay, [List<UsageEvent> events = const []]) {
  db.execute('''
CREATE TABLE IF NOT EXISTS day_stats(day TEXT NOT NULL, kind TEXT NOT NULL, n INTEGER NOT NULL, PRIMARY KEY(day, kind)) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS app_stats(day TEXT NOT NULL, app TEXT NOT NULL, kind TEXT NOT NULL, n INTEGER NOT NULL, PRIMARY KEY(day, app, kind)) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS slot_stats(day TEXT NOT NULL, slot INTEGER NOT NULL, app TEXT NOT NULL, kind TEXT NOT NULL, n INTEGER NOT NULL, PRIMARY KEY(day, slot, app, kind)) WITHOUT ROWID;
''');
  db.execute('BEGIN');
  try {
    final from = firstDay.millisecondsSinceEpoch ~/ 1000;
    final to = DateTime(lastDay.year, lastDay.month, lastDay.day + 1).millisecondsSinceEpoch ~/ 1000;
    final put = db.prepare('INSERT OR REPLACE INTO sessions(app, start, stop, state) VALUES(?, ?, ?, 0)');
    for (final s in sessions) {
      put.execute([s.app, s.start, s.stop]);
    }
    put.dispose();
    final all = <SessionSpan>[];
    final lowest = from - sessionSlack(db, sessions);
    for (final r in db.select('SELECT app, start, stop FROM sessions WHERE start >= ?3 AND start < ?2 AND stop > ?1', [from, to, lowest])) {
      all.add(SessionSpan(r['app'] as String, r['start'] as int, r['stop'] as int));
    }
    final putUsage = db.prepare('INSERT INTO usage(day, app, state, ms) VALUES(?, ?, 0, ?)');
    final putSlot = db.prepare('INSERT INTO timeline(day, slot, app, state, ms) VALUES(?, ?, ?, 0, ?)');
    final putDayStat = db.prepare('INSERT INTO day_stats(day, kind, n) VALUES(?, ?, ?)');
    final putAppStat = db.prepare('INSERT INTO app_stats(day, app, kind, n) VALUES(?, ?, ?, ?)');
    final putSlotStat = db.prepare('INSERT INTO slot_stats(day, slot, app, kind, n) VALUES(?, ?, ?, ?, ?)');
    var day = firstDay;
    while (!day.isAfter(lastDay)) {
      final key = dayKey(day);
      final dayNext = DateTime(day.year, day.month, day.day + 1);
      final aMs = day.millisecondsSinceEpoch;
      final bMs = dayNext.millisecondsSinceEpoch;
      final aSec = aMs ~/ 1000;
      final bSec = bMs ~/ 1000;
      db.execute('DELETE FROM usage WHERE day = ?', [key]);
      db.execute('DELETE FROM timeline WHERE day = ?', [key]);
      db.execute("DELETE FROM app_stats WHERE day = ? AND kind = 'opens'", [key]);
      db.execute("DELETE FROM slot_stats WHERE day = ? AND kind = 'opens'", [key]);
      final totals = aggregateDay(all, day);
      totals.usage.forEach((app, ms) => putUsage.execute([key, app, ms]));
      totals.timeline.forEach((k, ms) {
        final i = k.indexOf('\u0000');
        putSlot.execute([key, int.parse(k.substring(0, i)), k.substring(i + 1), ms]);
      });
      final opens = <String, int>{};
      final slotOpens = <String, int>{};
      for (final s in all) {
        if (s.start >= aSec && s.start < bSec) {
          opens[s.app] = (opens[s.app] ?? 0) + 1;
          final sl = ((s.start - aSec) ~/ 300).clamp(0, 287);
          final sk = '$sl\u0000${s.app}';
          slotOpens[sk] = (slotOpens[sk] ?? 0) + 1;
        }
      }
      opens.forEach((app, n) => putAppStat.execute([key, app, 'opens', n]));
      slotOpens.forEach((sk, n) {
        final i = sk.indexOf('\u0000');
        putSlotStat.execute([key, int.parse(sk.substring(0, i)), sk.substring(i + 1), 'opens', n]);
      });
      var dayEvents = 0;
      var unlocks = 0;
      final notifs = <String, int>{};
      final slotUnlocks = <int, int>{};
      final slotNotifs = <String, int>{};
      for (final ev in events) {
        if (ev.ms < aMs || ev.ms >= bMs) continue;
        dayEvents++;
        final sl = ((ev.ms - aMs) ~/ 300000).clamp(0, 287);
        if (ev.type == evUnlock) {
          unlocks++;
          slotUnlocks[sl] = (slotUnlocks[sl] ?? 0) + 1;
        } else if (ev.type == evNotif && ev.pkg.isNotEmpty) {
          notifs[ev.pkg] = (notifs[ev.pkg] ?? 0) + 1;
          final nk = '$sl\u0000${ev.pkg}';
          slotNotifs[nk] = (slotNotifs[nk] ?? 0) + 1;
        }
      }
      if (dayEvents > 0 || unlocks > 0 || notifs.isNotEmpty) {
        db.execute("DELETE FROM day_stats WHERE day = ? AND kind = 'unlocks'", [key]);
        db.execute("DELETE FROM app_stats WHERE day = ? AND kind = 'notifs'", [key]);
        db.execute("DELETE FROM slot_stats WHERE day = ? AND kind IN ('unlocks', 'notifs')", [key]);
        if (unlocks > 0) putDayStat.execute([key, 'unlocks', unlocks]);
        notifs.forEach((app, n) => putAppStat.execute([key, app, 'notifs', n]));
        slotUnlocks.forEach((sl, n) => putSlotStat.execute([key, sl, '', 'unlocks', n]));
        slotNotifs.forEach((nk, n) {
          final i = nk.indexOf('\u0000');
          putSlotStat.execute([key, int.parse(nk.substring(0, i)), nk.substring(i + 1), 'notifs', n]);
        });
      }
      day = dayNext;
    }
    putUsage.dispose();
    putSlot.dispose();
    putDayStat.dispose();
    putAppStat.dispose();
    putSlotStat.dispose();
    db.execute('COMMIT');
  } catch (_) {
    db.execute('ROLLBACK');
    rethrow;
  }
}

class UsageBridge {
  static const _channel = MethodChannel('wolium/usage');

  Future<bool> hasAccess() async => (await _channel.invokeMethod<bool>('hasAccess')) ?? false;

  Future<void> openSettings() async => _channel.invokeMethod('openSettings');

  Future<List<UsageEvent>> events(int fromMs, int toMs) async {
    final raw = await _channel.invokeMethod<List<dynamic>>('events', {'from': fromMs, 'to': toMs}) ?? const [];
    return [for (final e in raw) UsageEvent(e['pkg'] as String, e['type'] as int, e['time'] as int)];
  }

  Future<bool> openApp(String pkg) async => (await _channel.invokeMethod<bool>('openApp', {'pkg': pkg})) ?? false;

  Future<bool> appInfo(String pkg) async => (await _channel.invokeMethod<bool>('appInfo', {'pkg': pkg})) ?? false;


  Future<String> label(String pkg) async => (await _channel.invokeMethod<String>('label', {'pkg': pkg})) ?? pkg;

  Future<String?> takeAction() async => _channel.invokeMethod<String>('takeAction');

  Future<void> requestNotifications() async => _channel.invokeMethod('requestNotifications');

  Future<void> setApiService(bool on) async => _channel.invokeMethod('apiService', {'on': on});

  Future<void> setP2pService(bool on) async => _channel.invokeMethod('p2pService', {'on': on});

  Future<void> setCrashLogs(bool on) async => _channel.invokeMethod('setCrashLogs', {'on': on});

  Future<bool> getCrashLogs() async => (await _channel.invokeMethod<bool>('getCrashLogs')) ?? true;

  Future<Uint8List?> icon(String pkg) async => _channel.invokeMethod<Uint8List>('icon', {'pkg': pkg});

  Future<String?> saveFile(String name, List<int> bytes, {String mime = 'text/csv'}) async =>
      _channel.invokeMethod<String>('saveFile', {'name': name, 'bytes': Uint8List.fromList(bytes), 'mime': mime});

  Future<Uint8List?> pickFile() async => _channel.invokeMethod<Uint8List>('pickFile');
}

Future<String?> saveBackup(UsageBridge bridge) async {
  final db = sqlite3.open(dbPath());
  try {
    db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
  } finally {
    db.dispose();
  }
  final bytes = File(dbPath()).readAsBytesSync();
  return bridge.saveFile('wolium_backup.db', bytes, mime: 'application/octet-stream');
}

Future<bool?> restoreBackup(UsageBridge bridge) async {
  final bytes = await bridge.pickFile();
  if (bytes == null) return null;
  if (bytes.length < 100 || String.fromCharCodes(bytes.sublist(0, 15)) != 'SQLite format 3') return false;
  final tmp = File('${Directory.systemTemp.path}${Platform.pathSeparator}wolium_restore.db')..writeAsBytesSync(bytes);
  final db = sqlite3.open(dbPath());
  try {
    db.execute(_schema);
    db.execute('ATTACH DATABASE ? AS b', [tmp.path]);
    db.execute('BEGIN');
    try {
      db.execute('INSERT OR IGNORE INTO usage(day, app, state, ms) SELECT day, app, state, ms FROM b.usage WHERE day NOT IN (SELECT day FROM main.usage)');
      db.execute('INSERT OR IGNORE INTO timeline(day, slot, app, state, ms) SELECT day, slot, app, state, ms FROM b.timeline WHERE day NOT IN (SELECT day FROM main.timeline)');
      db.execute('INSERT OR IGNORE INTO sessions(app, start, stop, state) SELECT app, start, stop, state FROM b.sessions');
      db.execute("INSERT OR IGNORE INTO apps(app, name, path) SELECT app, name, '' FROM b.apps");
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
    db.execute('DETACH DATABASE b');
    return true;
  } catch (_) {
    return false;
  } finally {
    db.dispose();
    try {
      tmp.deleteSync();
    } catch (_) {}
  }
}

class AndroidCollector {
  AndroidCollector(this.bridge);

  final UsageBridge bridge;
  Timer? _timer;
  bool _busy = false;
  final ValueNotifier<bool> access = ValueNotifier<bool>(true);

  File get _marker => File('${dataDir()}${Platform.pathSeparator}sync');

  Timer? _quick;

  void start() {
    sync();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => sync());
    _quick = Timer.periodic(const Duration(seconds: 3), (_) async {
      final ok = await bridge.hasAccess();
      final changed = ok != access.value;
      access.value = ok;
      if (changed && ok) sync();
    });
  }

  void stop() {
    _timer?.cancel();
    _quick?.cancel();
  }

  Future<void> sync() async {
    if (_busy) return;
    _busy = true;
    try {
      final ok = await bridge.hasAccess();
      access.value = ok;
      if (!Settings.load().accepted) return;
      if (!ok || File('${dataDir()}${Platform.pathSeparator}paused').existsSync()) return;
      final now = DateTime.now();
      var since = now.subtract(const Duration(days: 7));
      try {
        if (_marker.existsSync()) {
          final last = DateTime.fromMillisecondsSinceEpoch(int.parse(_marker.readAsStringSync().trim()));
          since = last.subtract(const Duration(minutes: 10));
        }
      } catch (_) {}
      final firstDay = DateTime(since.year, since.month, since.day);
      final queryFrom = firstDay.subtract(const Duration(hours: 1));
      final events = await bridge.events(queryFrom.millisecondsSinceEpoch, now.millisecondsSinceEpoch);
      final sessions = buildSessions(events, now.millisecondsSinceEpoch);
      Directory(dataDir()).createSync(recursive: true);
      final db = sqlite3.open(dbPath());
      try {
        db.execute(_schema);
        storeSessions(db, sessions, firstDay, DateTime(now.year, now.month, now.day), events);
        final known = {
          for (final r in db.select("SELECT app, path FROM apps WHERE path != ''"))
            if (File(r['path'] as String).existsSync()) r['app'] as String
        };
        for (final app in sessions.map((s) => s.app).toSet()) {
          if (known.contains(app)) continue;
          final label = await bridge.label(app);
          var iconPath = '';
          try {
            final png = await bridge.icon(app);
            if (png != null && png.isNotEmpty) {
              final dir = Directory('${dataDir()}${Platform.pathSeparator}icons')..createSync(recursive: true);
              iconPath = '${dir.path}${Platform.pathSeparator}$app.png';
              File(iconPath).writeAsBytesSync(png);
            }
          } catch (_) {}
          db.execute('INSERT OR REPLACE INTO apps(app, name, path) VALUES(?, ?, ?)', [app, label, iconPath]);
        }
        db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
      } finally {
        db.dispose();
      }
      _marker.writeAsStringSync('${now.millisecondsSinceEpoch}');
    } catch (_) {
    } finally {
      _busy = false;
    }
  }
}
