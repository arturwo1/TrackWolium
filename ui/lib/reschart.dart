import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'data.dart';
import 'forecast.dart';
import 'l10n.dart';

const seriesColors = [
  Color(0xFF4F8CFF),
  Color(0xFF3DD68C),
  Color(0xFFFF9F43),
  Color(0xFFB07CFF),
  Color(0xFFFF5D8F),
  Color(0xFF2EC4D6),
  Color(0xFFE6C84B),
  Color(0xFF9AA5B1),
  Color(0xFFFF6B4A),
  Color(0xFF19B596),
  Color(0xFFD96BFF),
  Color(0xFFA6E22E),
  Color(0xFF7B9DFF),
  Color(0xFFFFC168),
  Color(0xFFE57373),
  Color(0xFF4DD0E1),
  Color(0xFFAED581),
  Color(0xFFF06292),
  Color(0xFFBA68C8),
  Color(0xFFFFD54F),
];

const statMetricIds = [
  'opens',
  'notifs',
  'unlocks',
  'appbattery',
  'power_sleep',
  'power_hibernate',
  'power_lock',
  'power_reboot',
  'power_shutdown',
];

const _idColor = {
  'cpu': 0,
  'ram': 1,
  'peak': 2,
  'ior': 3,
  'iow': 4,
  'sysram': 5,
  'sysdisk': 6,
  'battery': 7,
  'opens': 8,
  'notifs': 9,
  'unlocks': 10,
  'appbattery': 11,
  'power_sleep': 12,
  'power_hibernate': 13,
  'power_lock': 14,
  'power_reboot': 15,
  'power_shutdown': 16,
  'realfocus': 17,
};

Color metricColor(String id) => seriesColors[_idColor[id] ?? 0];

List<String> sizeUnits() => [tr('unitKB'), tr('unitMB'), tr('unitGB')];

String formatKb(int kb) => formatSize(kb * 1024, sizeUnits());

String formatBytes(int b) => formatSize(b, sizeUnits());

String formatCpuMs(int ms) => formatMs(ms);

String metricName(String id) {
  switch (id) {
    case 'realfocus':
      return tr('lineRealFocus');
    case 'cpu':
      return tr('mCpu');
    case 'ram':
      return tr('mRam');
    case 'peak':
      return tr('mPeak');
    case 'ior':
      return tr('mIoRead');
    case 'iow':
      return tr('mIoWrite');
    case 'sysram':
      return tr('mSysRam');
    case 'sysdisk':
      return tr('mSysDisk');
    case 'battery':
      return tr('mBattery');
    case 'opens':
      return tr('opens');
    case 'notifs':
      return tr('notifs');
    case 'unlocks':
      return tr('unlocksLabel');
    case 'appbattery':
      return tr('mAppBattery');
    case 'power_sleep':
      return tr('powerSleep');
    case 'power_hibernate':
      return tr('powerHibernate');
    case 'power_lock':
      return tr('powerLock');
    case 'power_reboot':
      return tr('powerReboot');
    case 'power_shutdown':
      return tr('powerShutdown');
    default:
      return id;
  }
}

class ResSeries {
  ResSeries(this.id, this.label, this.color, this.format, this.points, [List<Map<String, double>>? apps, this.prevPoints = const []])
      : apps = apps ?? List.generate(points.length, (_) => const <String, double>{});

  final String id;
  final String label;
  final Color color;
  final String Function(double) format;
  final List<Offset> points;
  final List<Map<String, double>> apps;
  final List<Offset> prevPoints;

  bool get isPeak => id == 'peak';
  bool get isSum => id == 'opens' || id == 'notifs' || id == 'unlocks' || id == 'appbattery' || id.startsWith('power_') || id == 'realfocus';

  static int lowerBound(List<Offset> list, double x) {
    var lo = 0;
    var hi = list.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (list[mid].dx < x) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  double maxIn(double a, double b) {
    var m = 0.0;
    for (var i = lowerBound(points, a); i < points.length; i++) {
      final p = points[i];
      if (p.dx > b) break;
      if (p.dy > m) m = p.dy;
    }
    return m;
  }

  ({double min, double max, double avg}) statsIn(double a, double b) {
    var minV = double.infinity;
    var maxV = 0.0;
    var sum = 0.0;
    var count = 0;
    for (var i = lowerBound(points, a); i < points.length; i++) {
      final p = points[i];
      if (p.dx > b) break;
      if (p.dy < minV) minV = p.dy;
      if (p.dy > maxV) maxV = p.dy;
      sum += p.dy;
      count++;
    }
    if (count == 0) return (min: 0.0, max: 0.0, avg: 0.0);
    return (min: minV, max: maxV, avg: sum / count);
  }

  double? prevValueIn(double a, double b) {
    if (prevPoints.isEmpty) return null;
    final list = <double>[];
    for (var i = lowerBound(prevPoints, a); i < prevPoints.length; i++) {
      final p = prevPoints[i];
      if (p.dx >= b) break;
      list.add(p.dy);
    }
    if (list.isNotEmpty) return _fold(list);
    final mid = (a + b) / 2;
    final i = lowerBound(prevPoints, mid);
    var best = -1;
    var bestDist = double.infinity;
    if (i < prevPoints.length) {
      best = i;
      bestDist = (prevPoints[i].dx - mid).abs();
    }
    if (i > 0 && (prevPoints[i - 1].dx - mid).abs() < bestDist) {
      best = i - 1;
      bestDist = (prevPoints[i - 1].dx - mid).abs();
    }
    if (best >= 0 && bestDist <= math.max(b - a, 600)) return prevPoints[best].dy;
    return null;
  }

  List<int> indexesIn(double a, double b) {
    final out = <int>[];
    for (var i = lowerBound(points, a); i < points.length; i++) {
      if (points[i].dx >= b) break;
      out.add(i);
    }
    if (out.isEmpty && points.isNotEmpty) {
      final mid = (a + b) / 2;
      final i = lowerBound(points, mid);
      var best = 0;
      var d = double.infinity;
      if (i < points.length) {
        best = i;
        d = (points[i].dx - mid).abs();
      }
      if (i > 0 && (points[i - 1].dx - mid).abs() < d) {
        best = i - 1;
        d = (points[i - 1].dx - mid).abs();
      }
      if (d <= math.max(b - a, 600)) out.add(best);
    }
    return out;
  }

  double _fold(Iterable<double> v) {
    final l = v.toList();
    if (l.isEmpty) return 0;
    if (isPeak) return l.reduce(math.max);
    if (isSum) return l.reduce((a, b) => a + b);
    return l.reduce((a, b) => a + b) / l.length;
  }

  double valueIn(double a, double b) => _fold([for (final i in indexesIn(a, b)) points[i].dy]);

  Map<String, double> appsIn(double a, double b) {
    final idx = indexesIn(a, b);
    final names = <String>{for (final i in idx) ...apps[i].keys};
    final out = <String, double>{};
    for (final n in names) {
      out[n] = _fold([for (final i in idx) apps[i][n] ?? 0.0]);
    }
    return out;
  }
}

final ValueNotifier<String?> seriesFocus = ValueNotifier<String?>(null);

int logicalCores() => math.max(1, Platform.numberOfProcessors);

String _cpuText(double v) => '${v.toStringAsFixed(v < 10 ? 1 : 0)}%';

String _rate(double v) => '${formatBytes(v.round())}/${tr('unitS')}';

String _size(double v) => formatKb(v.round());

String _countText(double v) => '${v.round()}';

String _pctText(double v) => '${v.round()}%';

String _pct1Text(double v) => '${v.toStringAsFixed(1)}%';

List<ResSeries> buildSeries({
  required Set<String> ids,
  required List<ResPoint> pts,
  required List<SysPoint> sys,
  String? only,
  required bool Function(String) skip,
  int bucketSec = 0,
  Map<String, String> deviceNames = const {},
}) {
  final out = <ResSeries>[];
  final step = bucketSec > 0 ? math.max(300, bucketSec) : 0;
  final bins = <int, Map<String, List<num>>>{};
  final spans = <int, int>{};
  for (final p in pts) {
    final bStart = step > 0 ? (p.start ~/ step) * step : p.start;
    final bSpan = step > 0 ? step : (p.end - p.start);
    final perApp = bins.putIfAbsent(bStart, () => {});
    spans[bStart] = bSpan;
    if (skip(p.app) || (only != null && p.app != only)) continue;
    final b = perApp.putIfAbsent(p.app, () => [0, 0, 0, 0, 0, 0]);
    b[0] += p.cpuMs;
    b[1] += p.ramKb;
    b[2] = math.max(b[2], p.peakKb);
    b[3] += p.ior;
    b[4] += p.iow;
    b[5] += 1;
    spans[bStart] = bSpan;
  }
  final cores = logicalCores();
  final starts = bins.keys.toList()..sort();
  ResSeries make(String id, int k, String Function(double) fmt, double Function(num v, int span, int cnt) f, {bool clampTotal = false}) {
    final points = <Offset>[];
    final apps = <Map<String, double>>[];
    for (final st in starts) {
      final span = spans[st]!;
      final per = <String, double>{};
      var total = 0.0;
      for (final e in bins[st]!.entries) {
        final cnt = e.value[5].toInt();
        final v = f(e.value[k], span, cnt <= 0 ? 1 : cnt);
        per[e.key] = v;
        total += v;
      }
      if (clampTotal && total > 100) total = 100;
      points.add(Offset(st + span / 2, total));
      apps.add(per);
    }
    return ResSeries(id, metricName(id), seriesColors[_idColor[id]!], fmt, points, apps);
  }

  if (ids.contains('cpu')) out.add(make('cpu', 0, _cpuText, (v, s, _) => v / (s * 1000) / cores * 100, clampTotal: true));
  if (ids.contains('ram')) out.add(make('ram', 1, _size, (v, _, c) => v / c));
  if (ids.contains('peak')) out.add(make('peak', 2, _size, (v, _, _) => v.toDouble()));
  if (ids.contains('ior')) out.add(make('ior', 3, _rate, (v, s, _) => v / s));
  if (ids.contains('iow')) out.add(make('iow', 4, _rate, (v, s, _) => v / s));
  final sysDevs = <String>[];
  for (final p in sys) {
    if (!sysDevs.contains(p.device)) sysDevs.add(p.device);
  }
  final multiDev = sysDevs.length > 1;
  if (ids.contains('sysram')) {
    if (!multiDev) {
      out.add(ResSeries('sysram', metricName('sysram'), seriesColors[_idColor['sysram']!], _size, [for (final p in sys) if (p.kind == 'ram') Offset(p.t.toDouble(), (p.total - p.free).toDouble())]));
    } else {
      for (var i = 0; i < sysDevs.length; i++) {
        final dev = sysDevs[i];
        final ptsDev = [for (final p in sys) if (p.device == dev && p.kind == 'ram') Offset(p.t.toDouble(), (p.total - p.free).toDouble())];
        if (ptsDev.isEmpty) continue;
        final dLabel = deviceNames[dev] ?? dev;
        out.add(ResSeries('sysram:$dev', '${metricName('sysram')} ($dLabel)', seriesColors[(5 + i * 2) % seriesColors.length], _size, ptsDev));
      }
    }
  }
  if (ids.contains('sysdisk')) {
    final keys = <({String device, String kind})>[];
    for (final p in sys) {
      if (p.kind.startsWith('disk:') && !keys.any((e) => e.device == p.device && e.kind == p.kind)) {
        keys.add((device: p.device, kind: p.kind));
      }
    }
    for (var i = 0; i < keys.length; i++) {
      final k = keys[i];
      final dLabel = deviceNames[k.device] ?? k.device;
      final mount = k.kind.substring(5);
      final label = multiDev ? '${metricName('sysdisk')} $mount ($dLabel)' : '${metricName('sysdisk')} $mount';
      final id = multiDev ? 'sysdisk:${k.device}:${k.kind}' : 'sysdisk:${k.kind}';
      out.add(ResSeries(id, label, seriesColors[(18 + i) % seriesColors.length], _size, [for (final p in sys) if (p.device == k.device && p.kind == k.kind) Offset(p.t.toDouble(), (p.total - p.free).toDouble())]));
    }
  }
  if (ids.contains('battery')) {
    final batDevs = <String>[];
    for (final p in sys) {
      if (p.kind == 'battery' && !batDevs.contains(p.device)) batDevs.add(p.device);
    }
    if (batDevs.length <= 1) {
      final ptsBat = [for (final p in sys) if (p.kind == 'battery') Offset(p.t.toDouble(), p.total.clamp(0, 100).toDouble())];
      if (ptsBat.isNotEmpty) {
        out.add(ResSeries('battery', metricName('battery'), seriesColors[_idColor['battery']!], _pctText, ptsBat));
      }
    } else {
      for (var i = 0; i < batDevs.length; i++) {
        final dev = batDevs[i];
        final ptsBat = [for (final p in sys) if (p.device == dev && p.kind == 'battery') Offset(p.t.toDouble(), p.total.clamp(0, 100).toDouble())];
        if (ptsBat.isEmpty) continue;
        final dLabel = deviceNames[dev] ?? dev;
        out.add(ResSeries('battery:$dev', '${metricName('battery')} ($dLabel)', seriesColors[(7 + i * 3) % seriesColors.length], _pctText, ptsBat));
      }
    }
  }
  return out;
}

List<ResSeries> buildStatSeries({
  required Set<String> ids,
  required List<StatPoint> pts,
  required int w0,
  required int w1,
  required int bin,
  int bucketSec = 0,
  int minSec = 0,
  int maxSec = 0,
  String? only,
  required bool Function(String) skip,
}) {
  final active = [for (final id in statMetricIds) if (ids.contains(id)) id];
  if (active.isEmpty || w1 <= w0) return const [];
  final step = bucketSec > 0 ? math.max(300, bucketSec) : math.max(300, bin >= 300 ? bin : bin * 300);
  final gridStart = (w0 ~/ step) * step;
  final out = <ResSeries>[];
  for (final kind in active) {
    final isSys = kind == 'unlocks' || kind.startsWith('power_');
    final isDuration = kind == 'power_sleep' || kind == 'power_hibernate' || kind == 'power_lock';
    final isBattery = kind == 'appbattery';
    final dbKind = isBattery ? 'battery' : kind;
    final byStart = <int, Map<String, double>>{};
    final sysTotals = <int, double>{};
    for (final p in pts) {
      if (p.kind != dbKind || p.count <= 0) continue;
      if (isDuration) {
        if (minSec > 0 && p.count < minSec * 1000) continue;
        if (maxSec > 0 && p.count > maxSec * 1000) continue;
      }
      final st = (p.start ~/ step) * step;
      if (isSys) {
        sysTotals[st] = (sysTotals[st] ?? 0) + p.count;
      } else {
        if (p.app.isEmpty || skip(p.app) || (only != null && p.app != only)) continue;
        final map = byStart.putIfAbsent(st, () => {});
        map[p.app] = (map[p.app] ?? 0) + (isBattery ? p.count / 10.0 : p.count.toDouble());
      }
    }
    final points = <Offset>[];
    final apps = <Map<String, double>>[];
    for (var st = gridStart; st < w1; st += step) {
      if (isSys) {
        points.add(Offset(st + step / 2, sysTotals[st] ?? 0.0));
        apps.add(const <String, double>{});
      } else {
        final per = byStart[st] ?? const <String, double>{};
        var total = 0.0;
        for (final v in per.values) {
          total += v;
        }
        points.add(Offset(st + step / 2, total));
        apps.add(per);
      }
    }
    final fmt = isDuration ? (double v) => formatMs(v.round()) : (isBattery ? _pct1Text : _countText);
    out.add(ResSeries(kind, metricName(kind), metricColor(kind), fmt, points, apps));
  }
  return out;
}
