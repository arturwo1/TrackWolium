import 'package:flutter/material.dart';
import 'data.dart';
import 'l10n.dart';
import 'theme.dart';

const _bucketSlots = 3;
const _bucketCount = 288 ~/ _bucketSlots;
const _bucketMs = _bucketSlots * 5 * 60 * 1000;

class Bucket {
  final Map<String, List<int>> apps = {};
  int value = 0;
}

List<Bucket> buildBuckets(List<Slot> slots, String? only) {
  final list = List.generate(_bucketCount, (_) => Bucket());
  for (final s in slots) {
    final i = (s.slot ~/ _bucketSlots).clamp(0, _bucketCount - 1);
    list[i].apps.putIfAbsent(s.app, () => [0, 0, 0])[s.state.clamp(0, 2)] += s.ms;
  }
  for (final b in list) {
    if (only != null) {
      b.value = b.apps[only]?[0] ?? 0;
    } else {
      b.value = b.apps.values.fold(0, (a, v) => a + v[0]);
    }
  }
  return list;
}

String _hm(int bucket) {
  final m = bucket * _bucketSlots * 5;
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(m ~/ 60 % 24)}:${two(m % 60)}';
}

class ActivityChart extends StatefulWidget {
  const ActivityChart({super.key, required this.slots, required this.only, required this.title, required this.height});

  final List<Slot> slots;
  final String? only;
  final String Function(String app) title;
  final double height;

  @override
  State<ActivityChart> createState() => _ActivityChartState();
}

class _ActivityChartState extends State<ActivityChart> {
  int? hover;

  void pick(double dx, double width) {
    final i = ((dx / width) * (_bucketCount - 1)).round().clamp(0, _bucketCount - 1);
    if (i != hover) setState(() => hover = i);
  }

  @override
  Widget build(BuildContext context) {
    final buckets = buildBuckets(widget.slots, widget.only);
    final peak = buckets.fold<int>(0, (a, b) => b.value > a ? b.value : a);
    final top = peak < 60000 ? 60000 : peak;
    return LayoutBuilder(builder: (context, c) {
      const left = 38.0;
      const bottom = 22.0;
      final plotW = c.maxWidth - left;
      return SizedBox(
        height: widget.height,
        width: c.maxWidth,
        child: MouseRegion(
          onExit: (_) => setState(() => hover = null),
          onHover: (e) => pick(e.localPosition.dx - left, plotW),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => pick(d.localPosition.dx - left, plotW),
            onHorizontalDragUpdate: (d) => pick(d.localPosition.dx - left, plotW),
            child: Stack(clipBehavior: Clip.none, children: [
              Positioned.fill(child: CustomPaint(painter: _ChartPainter(buckets, top, hover, left, bottom))),
              if (hover != null) _tooltip(buckets[hover!], hover!, c.maxWidth, plotW, left, bottom, top),
            ]),
          ),
        ),
      );
    });
  }

  Widget _tooltip(Bucket b, int i, double width, double plotW, double left, double bottom, int top) {
    final x = left + plotW * i / (_bucketCount - 1);
    final plotH = widget.height - bottom - 8;
    final y = 8 + plotH * (1 - b.value / top);
    final entries = b.apps.entries.toList()..sort((a, c) => c.value[0].compareTo(a.value[0]) != 0 ? c.value[0].compareTo(a.value[0]) : (c.value[1] + c.value[2]).compareTo(a.value[1] + a.value[2]));
    const boxW = 220.0;
    var dx = x - boxW / 2;
    if (dx < 0) dx = 0;
    if (dx + boxW > width) dx = width - boxW;
    final rows = entries.take(5).toList();
    final h = 56.0 + rows.length * 36;
    var dy = y - h - 10;
    if (dy < 0) dy = y + 14;
    return Positioned(
      left: dx,
      top: dy,
      width: boxW,
      child: IgnorePointer(
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: cBg,
            borderRadius: BorderRadius.circular(rSm),
            border: Border.fromBorderSide(line),
            boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 12)],
          ),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${_hm(i)} - ${_hm(i + 1)}', style: const TextStyle(color: cMuted, fontSize: 12, fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(formatMs(b.value), style: const TextStyle(color: cPrimary, fontWeight: FontWeight.w900, fontSize: 16)),
            if (rows.isEmpty)
              Padding(padding: const EdgeInsets.only(top: 4), child: Text(tr('noData'), style: const TextStyle(color: cMuted, fontSize: 12))),
            for (final e in rows)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(widget.title(e.key), overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                  Text(
                    [
                      if (e.value[0] > 0) '${tr('focused')} ${formatMs(e.value[0])}',
                      if (e.value[1] > 0) '${tr('open')} ${formatMs(e.value[1])}',
                      if (e.value[2] > 0) '${tr('minimized')} ${formatMs(e.value[2])}',
                    ].join(' · '),
                    style: const TextStyle(fontSize: 11, color: cMuted),
                  ),
                ]),
              ),
          ]),
        ),
      ),
    );
  }
}

class _ChartPainter extends CustomPainter {
  _ChartPainter(this.buckets, this.top, this.hover, this.left, this.bottom);

  final List<Bucket> buckets;
  final int top;
  final int? hover;
  final double left;
  final double bottom;

  Offset point(int i, Size size) {
    final w = size.width - left;
    final h = size.height - bottom - 8;
    return Offset(left + w * i / (_bucketCount - 1), 8 + h * (1 - buckets[i].value / top));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = cBorder
      ..strokeWidth = 1;
    final label = TextStyle(color: cMuted, fontSize: 11);
    final h = size.height - bottom - 8;
    for (var k = 0; k <= 2; k++) {
      final y = 8 + h * k / 2;
      canvas.drawLine(Offset(left, y), Offset(size.width, y), grid);
      final tp = TextPainter(text: TextSpan(text: formatMs((top * (2 - k) / 2).round()), style: label), textDirection: TextDirection.ltr)..layout();
      tp.paint(canvas, Offset(left - tp.width - 6, y - tp.height / 2));
    }
    for (final hour in [0, 6, 12, 18, 24]) {
      final x = left + (size.width - left) * hour / 24;
      final tp = TextPainter(text: TextSpan(text: '${hour.toString().padLeft(2, '0')}:00', style: label), textDirection: TextDirection.ltr)..layout();
      var dx = x - tp.width / 2;
      if (dx + tp.width > size.width) dx = size.width - tp.width;
      if (dx < left - 10) dx = left - 10;
      tp.paint(canvas, Offset(dx, size.height - tp.height));
    }

    final pts = [for (var i = 0; i < buckets.length; i++) point(i, size)];
    final baseY = 8 + h;
    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (var i = 0; i < pts.length - 1; i++) {
      final p0 = i == 0 ? pts[i] : pts[i - 1];
      final p1 = pts[i];
      final p2 = pts[i + 1];
      final p3 = i + 2 < pts.length ? pts[i + 2] : p2;
      double clampY(double y) => y.clamp(8.0, baseY);
      path.cubicTo(
        p1.dx + (p2.dx - p0.dx) / 6,
        clampY(p1.dy + (p2.dy - p0.dy) / 6),
        p2.dx - (p3.dx - p1.dx) / 6,
        clampY(p2.dy - (p3.dy - p1.dy) / 6),
        p2.dx,
        p2.dy,
      );
    }
    final fill = Path.from(path)
      ..lineTo(pts.last.dx, baseY)
      ..lineTo(pts.first.dx, baseY)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [cPrimary.withValues(alpha: 0.28), cPrimary.withValues(alpha: 0)])
            .createShader(Rect.fromLTWH(left, 8, size.width - left, h)),
    );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..strokeJoin = StrokeJoin.round
        ..color = cPrimary,
    );
    if (hover != null) {
      final p = pts[hover!];
      canvas.drawLine(Offset(p.dx, 8), Offset(p.dx, baseY), Paint()
        ..color = cPrimary.withValues(alpha: 0.35)
        ..strokeWidth = 1);
      canvas.drawCircle(p, 5, Paint()..color = cBg);
      canvas.drawCircle(
          p,
          5,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.2
            ..color = cPrimary);
    }
  }

  @override
  bool shouldRepaint(covariant _ChartPainter old) => true;
}
