import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:wolium/android_collector.dart';

void main() {
  test('foreground switches build back-to-back sessions', () {
    final s = buildSessions([
      const UsageEvent('a', evResumed, 1000000),
      const UsageEvent('b', evResumed, 1060000),
      const UsageEvent('b', evPaused, 1120000),
    ], 1200000);
    expect(s.length, 2);
    expect(s[0].app, 'a');
    expect(s[0].start, 1000);
    expect(s[0].stop, 1060);
    expect(s[1].stop, 1120);
  });

  test('screen off closes session and open session ends at now', () {
    final s = buildSessions([
      const UsageEvent('a', evResumed, 0),
      const UsageEvent('', evScreenOff, 30000),
      const UsageEvent('c', evResumed, 40000),
    ], 100000);
    expect(s.map((e) => '${e.app}:${e.start}-${e.stop}').toList(), ['a:0-30', 'c:40-100']);
  });

  test('sub-second sessions are dropped and unsorted input is handled', () {
    final s = buildSessions([
      const UsageEvent('a', evPaused, 500),
      const UsageEvent('a', evResumed, 0),
    ], 600);
    expect(s, isEmpty);
  });

  test('aggregation splits at day edge and five minute slots', () {
    final day = DateTime(2026, 11, 13);
    final a = day.millisecondsSinceEpoch ~/ 1000;
    final s = [SessionSpan('x', a - 60, a + 400)];
    final t = aggregateDay(s, day);
    expect(t.usage['x'], 400000);
    expect(t.timeline[DayTotals.key(0, 'x')], 300000);
    expect(t.timeline[DayTotals.key(1, 'x')], 100000);
  });

  test('storing sessions twice is idempotent', () {
    final db = sqlite3.openInMemory();
    db.execute('CREATE TABLE usage(day TEXT NOT NULL, app TEXT NOT NULL, state INTEGER NOT NULL, ms INTEGER NOT NULL, PRIMARY KEY(day, app, state));'
        'CREATE TABLE timeline(day TEXT NOT NULL, slot INTEGER NOT NULL, app TEXT NOT NULL, state INTEGER NOT NULL, ms INTEGER NOT NULL, PRIMARY KEY(day, slot, app, state));'
        'CREATE TABLE sessions(app TEXT NOT NULL, start INTEGER NOT NULL, stop INTEGER NOT NULL, state INTEGER NOT NULL, PRIMARY KEY(app, start));');
    final day = DateTime(2026, 11, 13);
    final a = day.millisecondsSinceEpoch ~/ 1000;
    final s = [SessionSpan('x', a + 10, a + 70)];
    storeSessions(db, s, day, day);
    storeSessions(db, s, day, day);
    expect(db.select('SELECT ms FROM usage').first['ms'], 60000);
    expect(db.select('SELECT COUNT(*) AS c FROM sessions').first['c'], 1);
  });
}
