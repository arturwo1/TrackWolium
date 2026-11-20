import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'data.dart';
import 'forecast.dart';
import 'l10n.dart';
import 'theme.dart';

const seriesColors = [
  Color(0xFF4F8CFF),
  Color(0xFF3DD68C),
  Color(0xFFFF9F43),
  Color(0xFFB07CFF),
  Color(0xFFFF5D8F),
  Color(0xFF2EC4D6),
  Color(0xFFE6C84B),
  Color(0xFF9AA5B1),
];

const _idColor = {'cpu': 0, 'ram': 1, 'peak': 2, 'ior': 3, 'iow': 4, 'sysram': 5};

Color metricColor(String id) => seriesColors[_idColor[id] ?? 0];

List<String> sizeUnits() => [tr('unitKB'), tr('unitMB'), tr('unitGB')];

String formatKb(int kb) => formatSize(kb * 1024, sizeUnits());

String formatBytes(int b) => formatSize(b, sizeUnits());

String formatCpuMs(int ms) => formatMs(ms);

String metricName(String id) {
  switch (id) {
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
    default:
      return id;
  }
}

class ResSeries {
  ResSeries(this.id, this.label, this.color, this.format, this.points, [List<Map<String, double>>? apps]) : apps = apps ?? List.generate(points.length, (_) => const <String, double>{});

  final String id;
  final String label;
  final Color color;
  final String Function(double) format;
  final List<Offset> points;
  final List<Map<String, double>> apps;

  bool get isPeak => id == 'peak';

  double maxIn(double a, double b) {
    var m = 0.0;
    for (final p in points) {
      if (p.dx >= a && p.dx <= b && p.dy > m) m = p.dy;
    }
    return m;
  }

  List<int> indexesIn(double a, double b) {
    final out = <int>[];
    for (var i = 0; i < points.length; i++) {
      if (points[i].dx >= a && points[i].dx < b) out.add(i);
    }
    if (out.isEmpty && points.isNotEmpty) {
      final mid = (a + b) / 2;
      var best = 0;
      var d = double.infinity;
      for (var i = 0; i < points.length; i++) {
        final dist = (points[i].dx - mid).abs();
        if (dist < d) {
          d = dist;
          best = i;
        }
      }
      if (d <= math.max(b - a, 600)) out.add(best);
    }
    return out;
  }

  double _fold(Iterable<double> v) {
    final l = v.toList();
    if (l.isEmpty) return 0;
    if (isPeak) return l.reduce(math.max);
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

List<ResSeries> buildSeries({required Set<String> ids, required List<ResPoint> pts, required List<SysPoint> sys, String? only, required bool Function(String) skip}) {
  final out = <ResSeries>[];
  final bins = <int, Map<String, List<num>>>{};
  final spans = <int, int>{};
  for (final p in pts) {
    if (skip(p.app) || (only != null && p.app != only)) continue;
    final b = bins.putIfAbsent(p.start, () => {}).putIfAbsent(p.app, () => [0, 0, 0, 0, 0]);
    b[0] += p.cpuMs;
    b[1] += p.ramKb;
    b[2] += p.peakKb;
    b[3] += p.ior;
    b[4] += p.iow;
    spans[p.start] = p.end - p.start;
  }
  final cores = logicalCores();
  final starts = bins.keys.toList()..sort();
  ResSeries make(String id, int k, String Function(double) fmt, double Function(num v, int span) f, {bool clampTotal = false}) {
    final points = <Offset>[];
    final apps = <Map<String, double>>[];
    for (final st in starts) {
      final span = spans[st]!;
      final per = <String, double>{};
      var total = 0.0;
      for (final e in bins[st]!.entries) {
        final v = f(e.value[k], span);
        per[e.key] = v;
        total += v;
      }
      if (clampTotal && total > 100) total = 100;
      points.add(Offset(st + span / 2, total));
      apps.add(per);
    }
    return ResSeries(id, metricName(id), seriesColors[_idColor[id]!], fmt, points, apps);
  }

  if (ids.contains('cpu')) out.add(make('cpu', 0, _cpuText, (v, s) => v / (s * 1000) / cores * 100, clampTotal: true));
  if (ids.contains('ram')) out.add(make('ram', 1, _size, (v, s) => v.toDouble()));
  if (ids.contains('peak')) out.add(make('peak', 2, _size, (v, s) => v.toDouble()));
  if (ids.contains('ior')) out.add(make('ior', 3, _rate, (v, s) => v / s));
  if (ids.contains('iow')) out.add(make('iow', 4, _rate, (v, s) => v / s));
  if (ids.contains('sysram')) {
    out.add(ResSeries('sysram', metricName('sysram'), seriesColors[_idColor['sysram']!], _size, [for (final p in sys) if (p.kind == 'ram') Offset(p.t.toDouble(), (p.total - p.free).toDouble())]));
  }
  if (ids.contains('sysdisk')) {
    final kinds = <String>[];
    for (final p in sys) {
      if (p.kind.startsWith('disk:') && !kinds.contains(p.kind)) kinds.add(p.kind);
    }
    for (var i = 0; i < kinds.length; i++) {
      final k = kinds[i];
      out.add(ResSeries('sysdisk:$k', '${metricName('sysdisk')} ${k.substring(5)}', seriesColors[(6 + i) % seriesColors.length], _size, [for (final p in sys) if (p.kind == k) Offset(p.t.toDouble(), (p.total - p.free).toDouble())]));
    }
  }
  return out;
}
