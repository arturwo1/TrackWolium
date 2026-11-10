import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'data.dart';
import 'l10n.dart';
import 'theme.dart';

enum Metric { focused, open, minimized, visible }

String metricLabel(Metric m) {
  switch (m) {
    case Metric.focused:
      return tr('focused');
    case Metric.open:
      return tr('open');
    case Metric.minimized:
      return tr('minimized');
    case Metric.visible:
      return tr('visibleAll');
  }
}

int metricOf(List<int> v, Metric m) {
  switch (m) {
    case Metric.focused:
      return v[0];
    case Metric.open:
      return v[1];
    case Metric.minimized:
      return v[2];
    case Metric.visible:
      return v[0] + v[1] + v[2];
  }
}

const _daySlots = 288;
const _minSpan = 12.0;
const _left = 42.0;
const _right = 10.0;
const _top = 8.0;
const _bottom = 22.0;
const _tipWidth = 250.0;
const _detailWidth = 236.0;

class Bucket {
  final Map<String, List<int>> apps = {};
  int value = 0;
}

class Session {
  Session(this.start, this.end, this.ms);

  final int start;
  final int end;
  final int ms;
}

String clock(int slot) {
  final m = slot * 5;
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(m ~/ 60 % 24)}:${two(m % 60)}';
}

List<Session> sessionsOf(List<Slot> slots, String app, Metric metric) {
  final per = <int, List<int>>{};
  for (final s in slots) {
    if (s.app != app) continue;
    per.putIfAbsent(s.slot, () => [0, 0, 0])[s.state.clamp(0, 2).toInt()] += s.ms;
  }
  final keys = per.keys.toList()..sort();
  final out = <Session>[];
  for (final k in keys) {
    final v = metricOf(per[k]!, metric);
    if (v <= 0) continue;
    if (out.isNotEmpty && out.last.end == k - 1) {
      final prev = out.last;
      out[out.length - 1] = Session(prev.start, k, prev.ms + v);
    } else {
      out.add(Session(k, k, v));
    }
  }
  return out;
}

class _Tip {
  const _Tip({required this.visible, required this.bucket, required this.anchor, required this.interactive, required this.follow, this.detail});

  final bool visible;
  final int bucket;
  final Offset anchor;
  final bool interactive;
  final bool follow;
  final String? detail;

  _Tip copyWith({bool? visible, int? bucket, Offset? anchor, bool? interactive, bool? follow, String? detail, bool clearDetail = false}) => _Tip(
        visible: visible ?? this.visible,
        bucket: bucket ?? this.bucket,
        anchor: anchor ?? this.anchor,
        interactive: interactive ?? this.interactive,
        follow: follow ?? this.follow,
        detail: clearDetail ? null : (detail ?? this.detail),
      );
}

class ActivityChart extends StatefulWidget {
  const ActivityChart({
    super.key,
    required this.slots,
    required this.only,
    required this.metric,
    required this.title,
    required this.icon,
    required this.height,
  });

  final List<Slot> slots;
  final String? only;
  final Metric metric;
  final String Function(String app) title;
  final Widget Function(String app, double size) icon;
  final double height;

  @override
  State<ActivityChart> createState() => _ActivityChartState();
}

class _ActivityChartState extends State<ActivityChart> {
  final key = GlobalKey();
  final tip = ValueNotifier<_Tip?>(null);
  OverlayEntry? entry;
  Timer? hideTimer;
  Timer? removeTimer;
  String? lastDetail;

  double vx0 = 0;
  double vx1 = _daySlots.toDouble();
  double lastScale = 1;
  bool touch = false;
  bool dragging = false;

  List<Bucket> buckets = [];
  int group = 3;
  int top = 60000;
  double plotW = 1;
  double plotH = 1;

  double get span => vx1 - vx0;

  @override
  void dispose() {
    hideTimer?.cancel();
    removeTimer?.cancel();
    entry?.remove();
    entry = null;
    tip.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ActivityChart old) {
    super.didUpdateWidget(old);
    entry?.markNeedsBuild();
  }

  void rebuildData() {
    group = span > 144 ? 3 : 1;
    final count = (_daySlots / group).ceil();
    final list = List.generate(count, (_) => Bucket());
    for (final s in widget.slots) {
      final i = (s.slot ~/ group).clamp(0, count - 1).toInt();
      list[i].apps.putIfAbsent(s.app, () => [0, 0, 0])[s.state.clamp(0, 2).toInt()] += s.ms;
    }
    var peak = 0;
    for (final b in list) {
      b.value = widget.only != null
          ? (b.apps[widget.only] == null ? 0 : metricOf(b.apps[widget.only]!, widget.metric))
          : b.apps.values.fold(0, (a, v) => a + metricOf(v, widget.metric));
      if (b.value > peak) peak = b.value;
    }
    buckets = list;
    top = peak < 60000 ? 60000 : peak;
  }

  double slotCenter(int i) => i * group + (group - 1) / 2.0;

  double xOf(double slot) => _left + (slot - vx0) / span * plotW;

  double yOf(double value) => _top + plotH * (1 - value / top);

  double lineY(double x) {
    final slot = vx0 + (x - _left) / plotW * span;
    final f = (slot - (group - 1) / 2.0) / group;
    final i0 = f.floor().clamp(0, buckets.length - 1).toInt();
    final i1 = (i0 + 1).clamp(0, buckets.length - 1).toInt();
    final t = (f - i0).clamp(0.0, 1.0).toDouble();
    final v = buckets[i0].value * (1 - t) + buckets[i1].value * t;
    return yOf(v);
  }

  void clampView() {
    final s = span.clamp(_minSpan, _daySlots.toDouble()).toDouble();
    var a = vx0;
    if (a < 0) a = 0;
    if (a + s > _daySlots) a = _daySlots - s;
    vx0 = a;
    vx1 = a + s;
  }

  void zoomX(double factor, double focalSlot) {
    final s = (span / factor).clamp(_minSpan, _daySlots.toDouble()).toDouble();
    final ratio = (focalSlot - vx0) / span;
    vx0 = focalSlot - ratio * s;
    vx1 = vx0 + s;
    clampView();
  }

  void resetView() {
    setState(() {
      vx0 = 0;
      vx1 = _daySlots.toDouble();
    });
    hideNow();
  }

  int bucketAt(double dx) {
    final slot = vx0 + (dx - _left) / plotW * span;
    final i = ((slot - (group - 1) / 2.0) / group).round();
    return i.clamp(0, buckets.length - 1).toInt();
  }

  void show(Offset local, {required bool touchMode, bool pin = false}) {
    if (buckets.isEmpty) return;
    hideTimer?.cancel();
    removeTimer?.cancel();
    final box = key.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final i = bucketAt(local.dx);
    final Offset anchor;
    if (touchMode) {
      final y = yOf(buckets[i].value.toDouble()).clamp(_top, _top + plotH).toDouble();
      anchor = box.localToGlobal(Offset(xOf(slotCenter(i)), y));
    } else {
      anchor = box.localToGlobal(local);
    }
    if (entry == null) {
      entry = OverlayEntry(builder: buildOverlay);
      Overlay.of(context).insert(entry!);
    }
    final cur = tip.value;
    final base = cur ?? _Tip(visible: true, bucket: i, anchor: anchor, interactive: touchMode, follow: !touchMode);
    tip.value = base.copyWith(
      visible: true,
      bucket: i,
      anchor: (cur != null && cur.interactive && !touchMode) ? cur.anchor : anchor,
      interactive: touchMode || pin || (cur?.interactive ?? false),
      follow: !touchMode && !(pin || (cur?.interactive ?? false)),
    );
  }

  void scheduleHide([int ms = 90]) {
    hideTimer?.cancel();
    hideTimer = Timer(Duration(milliseconds: ms), hideNow);
  }

  void hideNow() {
    hideTimer?.cancel();
    final t = tip.value;
    if (t == null) return;
    tip.value = t.copyWith(visible: false, interactive: false, clearDetail: true);
    removeTimer?.cancel();
    removeTimer = Timer(const Duration(milliseconds: 260), () {
      entry?.remove();
      entry = null;
      tip.value = null;
    });
  }

  void cancelHide() {
    hideTimer?.cancel();
    removeTimer?.cancel();
    final t = tip.value;
    if (t != null && !t.visible) tip.value = t.copyWith(visible: true);
  }

  void onSignal(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    GestureBinding.instance.pointerSignalResolver.register(e, (_) {
      final focal = vx0 + (e.localPosition.dx - _left) / plotW * span;
      setState(() => zoomX(e.scrollDelta.dy < 0 ? 1.15 : 1 / 1.15, focal));
      hideNow();
    });
  }

  void onHover(PointerHoverEvent e) {
    if (e.kind != PointerDeviceKind.mouse || dragging) return;
    final t = tip.value;
    if (t != null && t.interactive) return;
    final p = e.localPosition;
    if (p.dx < _left || p.dx > _left + plotW || buckets.isEmpty) {
      scheduleHide();
      return;
    }
    if ((p.dy - lineY(p.dx)).abs() <= 16) {
      show(p, touchMode: false);
    } else {
      scheduleHide(60);
    }
  }

  void onTapUp(TapUpDetails d) {
    final p = d.localPosition;
    if (touch) {
      final t = tip.value;
      final i = bucketAt(p.dx);
      if (t != null && t.visible && t.bucket == i) {
        hideNow();
      } else {
        show(p, touchMode: true);
      }
      return;
    }
    final t = tip.value;
    if (t != null && t.interactive) {
      hideNow();
    } else if (t != null && t.visible) {
      show(p, touchMode: false, pin: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      plotW = math.max(1.0, c.maxWidth - _left - _right);
      plotH = math.max(1.0, widget.height - _top - _bottom);
      rebuildData();
      return Listener(
        onPointerDown: (e) {
          touch = e.kind != PointerDeviceKind.mouse;
          if (e.kind == PointerDeviceKind.mouse && e.buttons == kMiddleMouseButton) resetView();
        },
        onPointerSignal: onSignal,
        child: MouseRegion(
          cursor: dragging ? SystemMouseCursors.grabbing : SystemMouseCursors.basic,
          onHover: onHover,
          onExit: (_) {
            final t = tip.value;
            scheduleHide(t != null && t.interactive ? 900 : 60);
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: onTapUp,
            onDoubleTap: resetView,
            onScaleStart: (_) {
              lastScale = 1;
              dragging = true;
            },
            onScaleEnd: (_) => setState(() => dragging = false),
            onScaleUpdate: (d) {
              final moved = d.focalPointDelta.dx != 0 || d.scale != 1;
              setState(() {
                if (d.scale != 1) {
                  zoomX(d.scale / lastScale, vx0 + (d.localFocalPoint.dx - _left) / plotW * span);
                  lastScale = d.scale;
                }
                vx0 -= d.focalPointDelta.dx / plotW * span;
                vx1 = vx0 + span;
                clampView();
              });
              if (moved) hideNow();
            },
            child: SizedBox(
              key: key,
              width: c.maxWidth,
              height: widget.height,
              child: ClipRect(
                child: ValueListenableBuilder<_Tip?>(
                  valueListenable: tip,
                  builder: (context, t, _) => CustomPaint(
                    painter: _ChartPainter(
                      buckets: buckets,
                      group: group,
                      vx0: vx0,
                      vx1: vx1,
                      yBottom: 0,
                      ySpan: top.toDouble(),
                      hover: t != null && t.visible ? t.bucket : null,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    });
  }

  Widget buildOverlay(BuildContext overlayContext) {
    return ValueListenableBuilder<_Tip?>(
      valueListenable: tip,
      builder: (context, t, _) {
        if (t == null || t.bucket >= buckets.length) return const SizedBox.shrink();
        final screen = MediaQuery.of(context).size;
        final b = buckets[t.bucket];
        final rows = b.apps.entries
            .where((e) => metricOf(e.value, widget.metric) > 0 && (widget.only == null || e.key == widget.only))
            .toList()
          ..sort((a, c) => metricOf(c.value, widget.metric).compareTo(metricOf(a.value, widget.metric)));
        final visibleRows = math.min(rows.length, 6);
        final height = 70.0 + math.max(1, visibleRows) * 40.0;
        double left;
        double topPos;
        if (t.follow) {
          left = t.anchor.dx + 18;
          if (left + _tipWidth > screen.width - 8) left = t.anchor.dx - _tipWidth - 18;
          topPos = t.anchor.dy - height - 12;
          if (topPos < 8) topPos = t.anchor.dy + 22;
        } else if (t.interactive && !touch) {
          left = t.anchor.dx + 18;
          if (left + _tipWidth > screen.width - 8) left = t.anchor.dx - _tipWidth - 18;
          topPos = t.anchor.dy - height - 12;
          if (topPos < 8) topPos = t.anchor.dy + 22;
        } else {
          left = t.anchor.dx - _tipWidth / 2;
          topPos = t.anchor.dy - height - 14;
          if (topPos < 8) topPos = t.anchor.dy + 18;
        }
        left = left.clamp(8.0, math.max(8.0, screen.width - _tipWidth - 8)).toDouble();
        topPos = topPos.clamp(8.0, math.max(8.0, screen.height - height - 8)).toDouble();
        var detailLeft = left + _tipWidth + 8;
        if (detailLeft + _detailWidth > screen.width - 8) detailLeft = left - _detailWidth - 8;
        if (detailLeft < 8) detailLeft = 8;
        if (t.detail != null) lastDetail = t.detail;
        final shownDetail = lastDetail;
        final move = t.follow ? const Duration(milliseconds: 90) : const Duration(milliseconds: 200);

        Widget animated(Widget child, bool on) => TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: on ? 1 : 0),
              duration: const Duration(milliseconds: 170),
              curve: Curves.easeOutCubic,
              builder: (context, v, child) => Opacity(
                opacity: v,
                child: Transform.translate(
                  offset: Offset(0, (1 - v) * 6),
                  child: Transform.scale(scale: 0.97 + 0.03 * v, alignment: Alignment.bottomCenter, child: child),
                ),
              ),
              child: child,
            );

        return Stack(children: [
          AnimatedPositioned(
            duration: move,
            curve: Curves.easeOutCubic,
            left: left,
            top: topPos,
            width: _tipWidth,
            child: IgnorePointer(
              ignoring: !t.interactive,
              child: MouseRegion(
                onEnter: (_) => cancelHide(),
                onExit: (_) => scheduleHide(900),
                child: animated(_mainTip(b, t, rows), t.visible),
              ),
            ),
          ),
          if (shownDetail != null)
            AnimatedPositioned(
              duration: move,
              curve: Curves.easeOutCubic,
              left: detailLeft,
              top: topPos,
              width: _detailWidth,
              child: IgnorePointer(
                ignoring: !t.interactive || t.detail == null,
                child: MouseRegion(
                  onEnter: (_) => cancelHide(),
                  onExit: (_) => scheduleHide(900),
                  child: animated(_detailTip(shownDetail), t.visible && t.detail != null),
                ),
              ),
            ),
        ]);
      },
    );
  }

  BoxDecoration get _tipDecoration => BoxDecoration(
        color: cBg,
        borderRadius: BorderRadius.circular(rSm),
        border: Border.fromBorderSide(line),
        boxShadow: const [BoxShadow(color: Color(0x80000000), blurRadius: 16, offset: Offset(0, 4))],
      );

  Widget _mainTip(Bucket b, _Tip t, List<MapEntry<String, List<int>>> rows) {
    return Material(
      type: MaterialType.transparency,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: _tipDecoration,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${clock(t.bucket * group)} - ${clock((t.bucket + 1) * group)}', style: const TextStyle(color: cMuted, fontSize: 12, fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text('${metricLabel(widget.metric)}: ${formatMs(b.value)}', style: const TextStyle(color: cPrimary, fontWeight: FontWeight.w900, fontSize: 15)),
          const SizedBox(height: 6),
          if (rows.isEmpty)
            Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(tr('noData'), style: const TextStyle(color: cMuted, fontSize: 12)))
          else
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240),
              child: ListView(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                children: [
                  for (final e in rows)
                    HoverBox(
                      onTap: () {
                        final cur = tip.value;
                        if (cur != null) tip.value = cur.detail == e.key ? cur.copyWith(clearDetail: true) : cur.copyWith(detail: e.key);
                      },
                      builder: (hovered) => Container(
                        height: 36,
                        margin: const EdgeInsets.only(bottom: 2),
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        decoration: BoxDecoration(
                          color: t.detail == e.key ? cSoft : (hovered ? cSoft.withValues(alpha: 0.5) : Colors.transparent),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(children: [
                          widget.icon(e.key, 20),
                          const SizedBox(width: 8),
                          Expanded(child: EllipsisText(widget.title(e.key), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700))),
                          const SizedBox(width: 6),
                          Text(formatMs(metricOf(e.value, widget.metric)), style: const TextStyle(fontSize: 12, color: cMuted)),
                        ]),
                      ),
                    ),
                ],
              ),
            ),
          if (!t.interactive && rows.isNotEmpty)
            Padding(padding: const EdgeInsets.only(top: 4), child: Text(tr('clickToPin'), style: const TextStyle(color: cMuted, fontSize: 11))),
        ]),
      ),
    );
  }

  Widget _detailTip(String app) {
    final sessions = sessionsOf(widget.slots, app, widget.metric);
    final total = sessions.fold<int>(0, (a, s) => a + s.ms);
    return Material(
      type: MaterialType.transparency,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: _tipDecoration,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            widget.icon(app, 22),
            const SizedBox(width: 8),
            Expanded(child: EllipsisText(widget.title(app), style: const TextStyle(fontWeight: FontWeight.w800))),
          ]),
          const SizedBox(height: 4),
          Text('${metricLabel(widget.metric)}: ${formatMs(total)}', style: const TextStyle(color: cPrimary, fontWeight: FontWeight.w800, fontSize: 13)),
          const SizedBox(height: 6),
          Text(tr('sessions'), style: const TextStyle(color: cMuted, fontSize: 12, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 220),
            child: ListView(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              children: [
                for (final s in sessions)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(children: [
                      Expanded(child: Text('${clock(s.start)} - ${clock(s.end + 1)}', style: const TextStyle(fontSize: 13))),
                      Text(formatMs(s.ms), style: const TextStyle(fontSize: 12, color: cMuted)),
                    ]),
                  ),
              ],
            ),
          ),
        ]),
      ),
    );
  }
}

class _ChartPainter extends CustomPainter {
  _ChartPainter({required this.buckets, required this.group, required this.vx0, required this.vx1, required this.yBottom, required this.ySpan, required this.hover});

  final List<Bucket> buckets;
  final int group;
  final double vx0;
  final double vx1;
  final double yBottom;
  final double ySpan;
  final int? hover;

  @override
  void paint(Canvas canvas, Size size) {
    final plotW = size.width - _left - _right;
    final plotH = size.height - _top - _bottom;
    final span = vx1 - vx0;
    double xOf(double slot) => _left + (slot - vx0) / span * plotW;
    double yOf(double v) => _top + plotH * (1 - (v - yBottom) / ySpan);
    double center(int i) => i * group + (group - 1) / 2.0;

    final grid = Paint()
      ..color = cBorder
      ..strokeWidth = 1;
    const label = TextStyle(color: cMuted, fontSize: 11);
    for (var k = 0; k <= 2; k++) {
      final y = _top + plotH * k / 2;
      canvas.drawLine(Offset(_left, y), Offset(size.width - _right, y), grid);
      final v = yBottom + ySpan * (2 - k) / 2;
      final tp = TextPainter(text: TextSpan(text: formatMs(v.round()), style: label), textDirection: TextDirection.ltr)..layout();
      tp.paint(canvas, Offset(_left - tp.width - 6, y - tp.height / 2));
    }
    final step = span > 144 ? 72 : (span > 72 ? 36 : (span > 36 ? 12 : 6));
    final first = (vx0 / step).ceil() * step;
    for (var s = first; s <= vx1; s += step) {
      final x = xOf(s.toDouble());
      canvas.drawLine(Offset(x, _top), Offset(x, _top + plotH), grid..color = cBorder.withValues(alpha: 0.5));
      final tp = TextPainter(text: TextSpan(text: s >= _daySlots ? '24:00' : clock(s), style: label), textDirection: TextDirection.ltr)..layout();
      var dx = x - tp.width / 2;
      if (dx + tp.width > size.width) dx = size.width - tp.width;
      if (dx < _left - 10) dx = _left - 10;
      tp.paint(canvas, Offset(dx, size.height - tp.height));
    }
    if (buckets.isEmpty) return;

    canvas.save();
    canvas.clipRect(Rect.fromLTWH(_left, 0, plotW, _top + plotH + 1));
    var lo = 0;
    var hi = buckets.length - 1;
    for (var i = 0; i < buckets.length; i++) {
      if (xOf(center(i)) < _left) lo = i;
    }
    for (var i = buckets.length - 1; i >= 0; i--) {
      if (xOf(center(i)) > _left + plotW) hi = i;
    }
    final pts = [for (var i = lo; i <= hi; i++) Offset(xOf(center(i)), yOf(buckets[i].value.toDouble()))];
    final baseY = yOf(0);
    if (pts.length >= 2) {
      final path = Path()..moveTo(pts.first.dx, pts.first.dy);
      final minY = _top;
      final maxY = math.max(baseY, _top + plotH);
      for (var i = 0; i < pts.length - 1; i++) {
        final p0 = i == 0 ? pts[i] : pts[i - 1];
        final p1 = pts[i];
        final p2 = pts[i + 1];
        final p3 = i + 2 < pts.length ? pts[i + 2] : p2;
        double cy(double y) => y.clamp(minY - 200, maxY).toDouble();
        final lowest = math.max(p1.dy, p2.dy);
        final highest = math.min(p1.dy, p2.dy);
        double bound(double y) => y.clamp(highest, lowest).toDouble();
        path.cubicTo(
          p1.dx + (p2.dx - p0.dx) / 6,
          bound(cy(p1.dy + (p2.dy - p0.dy) / 6)),
          p2.dx - (p3.dx - p1.dx) / 6,
          bound(cy(p2.dy - (p3.dy - p1.dy) / 6)),
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
              .createShader(Rect.fromLTWH(_left, _top, plotW, plotH)),
      );
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.2
          ..strokeJoin = StrokeJoin.round
          ..color = cPrimary,
      );
    }
    if (hover != null && hover! < buckets.length) {
      final p = Offset(xOf(center(hover!)), yOf(buckets[hover!].value.toDouble()));
      canvas.drawLine(
          Offset(p.dx, _top),
          Offset(p.dx, _top + plotH),
          Paint()
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
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ChartPainter old) => true;
}
