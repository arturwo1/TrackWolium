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
  ResSeries(this.id, this.label, this.color, this.format, this.points);

  final String id;
  final String label;
  final Color color;
  final String Function(double) format;
  final List<Offset> points;

  double maxIn(double a, double b) {
    var m = 0.0;
    for (final p in points) {
      if (p.dx >= a && p.dx <= b && p.dy > m) m = p.dy;
    }
    return m;
  }
}

String _cpuText(double v) => '${v.toStringAsFixed(v < 10 ? 1 : 0)}%';

List<ResSeries> buildSeries({required Set<String> ids, required List<ResPoint> pts, required List<SysPoint> sys, String? only, required bool Function(String) skip}) {
  final out = <ResSeries>[];
  final bins = <int, List<num>>{};
  final spans = <int, int>{};
  for (final p in pts) {
    if (skip(p.app) || (only != null && p.app != only)) continue;
    final b = bins.putIfAbsent(p.start, () => [0, 0, 0, 0, 0]);
    b[0] += p.cpuMs;
    b[1] += p.ramKb;
    b[2] += p.peakKb;
    b[3] += p.ior;
    b[4] += p.iow;
    spans[p.start] = p.end - p.start;
  }
  final starts = bins.keys.toList()..sort();
  List<Offset> line(double Function(List<num> v, int span) f) => [for (final s in starts) Offset(s + spans[s]! / 2, f(bins[s]!, spans[s]!))];
  if (ids.contains('cpu')) out.add(ResSeries('cpu', metricName('cpu'), seriesColors[_idColor['cpu']!], _cpuText, line((v, s) => v[0] / (s * 1000) * 100)));
  if (ids.contains('ram')) out.add(ResSeries('ram', metricName('ram'), seriesColors[_idColor['ram']!], (v) => formatKb(v.round()), line((v, s) => v[1].toDouble())));
  if (ids.contains('peak')) out.add(ResSeries('peak', metricName('peak'), seriesColors[_idColor['peak']!], (v) => formatKb(v.round()), line((v, s) => v[2].toDouble())));
  if (ids.contains('ior')) out.add(ResSeries('ior', metricName('ior'), seriesColors[_idColor['ior']!], (v) => '${formatBytes(v.round())}/${tr('unitS')}', line((v, s) => v[3] / s)));
  if (ids.contains('iow')) out.add(ResSeries('iow', metricName('iow'), seriesColors[_idColor['iow']!], (v) => '${formatBytes(v.round())}/${tr('unitS')}', line((v, s) => v[4] / s)));
  if (ids.contains('sysram')) {
    out.add(ResSeries('sysram', metricName('sysram'), seriesColors[_idColor['sysram']!], (v) => formatKb(v.round()), [for (final p in sys) if (p.kind == 'ram') Offset(p.t.toDouble(), (p.total - p.free).toDouble())]));
  }
  if (ids.contains('sysdisk')) {
    final kinds = <String>[];
    for (final p in sys) {
      if (p.kind.startsWith('disk:') && !kinds.contains(p.kind)) kinds.add(p.kind);
    }
    for (var i = 0; i < kinds.length; i++) {
      final k = kinds[i];
      out.add(ResSeries('sysdisk:$k', '${metricName('sysdisk')} ${k.substring(5)}', seriesColors[(6 + i) % seriesColors.length], (v) => formatKb(v.round()), [for (final p in sys) if (p.kind == k) Offset(p.t.toDouble(), (p.total - p.free).toDouble())]));
    }
  }
  return out;
}

class ResourceChart extends StatefulWidget {
  const ResourceChart({super.key, required this.series, required this.first, required this.viewFrom, required this.viewTo, this.height = 180});

  final List<ResSeries> series;
  final DateTime first;
  final double viewFrom;
  final double viewTo;
  final double height;

  @override
  State<ResourceChart> createState() => _ResourceChartState();
}

class _ResourceChartState extends State<ResourceChart> {
  final hidden = <String>{};
  double? hoverX;

  String timeText(double sec) {
    final t = widget.first.add(Duration(seconds: sec.round()));
    final hm = '${two2(t.hour)}:${two2(t.minute)}';
    return widget.viewTo - widget.viewFrom > 86400 ? '${two2(t.day)}.${two2(t.month)} $hm' : hm;
  }

  String two2(int v) => v.toString().padLeft(2, '0');

  Widget legendChip(ResSeries s) {
    final off = hidden.contains(s.id);
    final mx = s.maxIn(widget.viewFrom, widget.viewTo);
    return InkWell(
      borderRadius: BorderRadius.circular(rSm),
      onTap: () => setState(() => off ? hidden.remove(s.id) : hidden.add(s.id)),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(rSm),
          border: Border.all(color: off ? cBorder : s.color),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 10, height: 10, decoration: BoxDecoration(color: off ? cMuted.withValues(alpha: 0.4) : s.color, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Text(s.label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: off ? cMuted : null, decoration: off ? TextDecoration.lineThrough : null)),
          if (!off && mx > 0) Text('  ${tr('resMax')} ${s.format(mx)}', style: const TextStyle(fontSize: 11, color: cMuted)),
        ]),
      ),
    );
  }

  Offset? nearest(ResSeries s, double x) {
    Offset? best;
    var d = double.infinity;
    for (final p in s.points) {
      if (p.dx < widget.viewFrom || p.dx > widget.viewTo) continue;
      final dist = (p.dx - x).abs();
      if (dist < d) {
        d = dist;
        best = p;
      }
    }
    return best;
  }

  @override
  Widget build(BuildContext context) {
    final visible = [for (final s in widget.series) if (!hidden.contains(s.id)) s];
    final span = math.max(1.0, widget.viewTo - widget.viewFrom);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: 8, runSpacing: 6, children: [for (final s in widget.series) legendChip(s)]),
      const SizedBox(height: 8),
      LayoutBuilder(builder: (context, c) {
        final w = c.maxWidth;
        double? x = hoverX;
        final tipLines = <Widget>[];
        double? tipAt;
        if (x != null && widget.series.isNotEmpty) {
          final t = widget.viewFrom + (x / w).clamp(0.0, 1.0) * span;
          tipAt = t;
          for (final s in visible) {
            final p = nearest(s, t);
            if (p == null) continue;
            tipLines.add(Row(mainAxisSize: MainAxisSize.min, children: [
              Container(width: 8, height: 8, decoration: BoxDecoration(color: s.color, shape: BoxShape.circle)),
              const SizedBox(width: 6),
              Text('${s.label}: ${s.format(p.dy)}', style: const TextStyle(fontSize: 12)),
            ]));
          }
        }
        return MouseRegion(
          onHover: (e) => setState(() => hoverX = e.localPosition.dx),
          onExit: (_) => setState(() => hoverX = null),
          child: GestureDetector(
            onTapDown: (d) => setState(() => hoverX = d.localPosition.dx),
            onHorizontalDragUpdate: (d) => setState(() => hoverX = d.localPosition.dx),
            child: SizedBox(
              height: widget.height,
              width: w,
              child: Stack(children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _ResPainter(visible, widget.viewFrom, widget.viewTo, hoverX, timeText),
                  ),
                ),
                if (tipAt != null && tipLines.isNotEmpty)
                  Positioned(
                    left: (x! + 12 + 190 > w) ? math.max(0, x - 12 - 190) : x + 12,
                    top: 4,
                    child: IgnorePointer(
                      child: Container(
                        width: 190,
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(color: cBg, borderRadius: BorderRadius.circular(rSm), border: Border.all(color: cBorder)),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                          Text(timeText(tipAt), style: const TextStyle(color: cMuted, fontSize: 11, fontWeight: FontWeight.w700)),
                          const SizedBox(height: 4),
                          ...tipLines,
                        ]),
                      ),
                    ),
                  ),
              ]),
            ),
          ),
        );
      }),
      const SizedBox(height: 6),
      Text(tr('resScaleNote'), style: const TextStyle(color: cMuted, fontSize: 11)),
    ]);
  }
}

class _ResPainter extends CustomPainter {
  _ResPainter(this.series, this.from, this.to, this.hoverX, this.timeText);

  final List<ResSeries> series;
  final double from;
  final double to;
  final double? hoverX;
  final String Function(double) timeText;

  @override
  void paint(Canvas canvas, Size size) {
    const bottom = 18.0;
    final h = size.height - bottom;
    final w = size.width;
    final span = math.max(1.0, to - from);
    final grid = Paint()
      ..color = cBorder
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final y = h * i / 4;
      canvas.drawLine(Offset(0, y), Offset(w, y), grid);
    }
    final label = TextPainter(textDirection: TextDirection.ltr);
    for (var i = 0; i <= 4; i++) {
      final t = from + span * i / 4;
      label.text = TextSpan(text: timeText(t), style: const TextStyle(color: cMuted, fontSize: 10));
      label.layout();
      final x = (w * i / 4 - (i == 4 ? label.width : (i == 0 ? 0 : label.width / 2))).clamp(0.0, math.max(0.0, w - label.width));
      label.paint(canvas, Offset(x, h + 4));
    }
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, w, h + 2));
    for (final s in series) {
      final pts = s.points.where((p) => p.dx >= from - span * 0.2 && p.dx <= to + span * 0.2).toList();
      if (pts.isEmpty) continue;
      final mx = s.maxIn(from, to);
      final scale = mx <= 0 ? 1.0 : mx;
      final paint = Paint()
        ..color = s.color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round;
      final path = Path();
      for (var i = 0; i < pts.length; i++) {
        final x = (pts[i].dx - from) / span * w;
        final y = h - (pts[i].dy / scale).clamp(0.0, 1.0) * (h - 4) - 2;
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      if (pts.length == 1) {
        final x = (pts[0].dx - from) / span * w;
        final y = h - (pts[0].dy / scale).clamp(0.0, 1.0) * (h - 4) - 2;
        canvas.drawCircle(Offset(x, y), 3, Paint()..color = s.color);
      }
      canvas.drawPath(path, paint);
    }
    canvas.restore();
    if (hoverX != null) {
      canvas.drawLine(Offset(hoverX!, 0), Offset(hoverX!, h), Paint()
        ..color = cMuted
        ..strokeWidth = 1);
    }
  }

  @override
  bool shouldRepaint(covariant _ResPainter old) => true;
}
