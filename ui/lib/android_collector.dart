import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:sqlite3/sqlite3.dart';
import 'data.dart';

const evResumed = 1;
const evPaused = 2;
const evScreenOff = 16;
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
''';

void storeSessions(Database db, List<SessionSpan> sessions, DateTime firstDay, DateTime lastDay) {
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
    for (final r in db.select('SELECT app, start, stop FROM sessions WHERE stop > ?1 AND start < ?2', [from, to])) {
      all.add(SessionSpan(r['app'] as String, r['start'] as int, r['stop'] as int));
    }
    final putUsage = db.prepare('INSERT INTO usage(day, app, state, ms) VALUES(?, ?, 0, ?)');
    final putSlot = db.prepare('INSERT INTO timeline(day, slot, app, state, ms) VALUES(?, ?, ?, 0, ?)');
    var day = firstDay;
    while (!day.isAfter(lastDay)) {
      final key = dayKey(day);
      db.execute('DELETE FROM usage WHERE day = ?', [key]);
      db.execute('DELETE FROM timeline WHERE day = ?', [key]);
      final totals = aggregateDay(all, day);
      totals.usage.forEach((app, ms) => putUsage.execute([key, app, ms]));
      totals.timeline.forEach((k, ms) {
        final i = k.indexOf('\u0000');
        putSlot.execute([key, int.parse(k.substring(0, i)), k.substring(i + 1), ms]);
      });
      day = DateTime(day.year, day.month, day.day + 1);
    }
    putUsage.dispose();
    putSlot.dispose();
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

  Future<String> label(String pkg) async => (await _channel.invokeMethod<String>('label', {'pkg': pkg})) ?? pkg;

  Future<Uint8List?> icon(String pkg) async => _channel.invokeMethod<Uint8List>('icon', {'pkg': pkg});

  Future<String?> saveFile(String name, List<int> bytes) async =>
      _channel.invokeMethod<String>('saveFile', {'name': name, 'bytes': Uint8List.fromList(bytes)});
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
        storeSessions(db, sessions, firstDay, DateTime(now.year, now.month, now.day));
        final known = {for (final r in db.select("SELECT app FROM apps WHERE path != ''")) r['app'] as String};
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
