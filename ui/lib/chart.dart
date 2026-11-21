import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'data.dart';
import 'haptics.dart';
import 'l10n.dart';
import 'reschart.dart';
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

final ValueNotifier<int> tipsReset = ValueNotifier<int>(0);
final ValueNotifier<bool> chartPinch = ValueNotifier<bool>(false);

const _daySec = 86400;
const _niceSteps = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200, 10800, 21600, 43200, 86400, 172800, 604800, 2592000, 7776000, 15552000, 31536000, 63072000];
const _minSpan = 30.0;
const _left = 54.0;
const _right = 10.0;
const _top = 8.0;
const _bottom = 22.0;
const _tipWidth = 250.0;
const _detailWidth = 250.0;

double? seriesValueAt(ResSeries s, double sec) {
  final p = s.points;
  if (p.isEmpty) return null;
  if (sec <= p.first.dx) return (p.first.dx - sec) <= 600 ? p.first.dy : null;
  if (sec >= p.last.dx) return (sec - p.last.dx) <= 600 ? p.last.dy : null;
  for (var i = 0; i < p.length - 1; i++) {
    if (sec >= p[i].dx && sec <= p[i + 1].dx) {
      final w = p[i + 1].dx - p[i].dx;
      final t = w <= 0 ? 0.0 : (sec - p[i].dx) / w;
      return p[i].dy * (1 - t) + p[i + 1].dy * t;
    }
  }
  return null;
}

double seriesScaleTop(ResSeries s, double a, double b) {
  final pad = (b - a) * 0.2;
  final m = s.maxIn(a - pad, b + pad);
  return (m <= 0 ? 1.0 : m) * 1.18;
}

int bucketSecFor(double span, double plotW) {
  final budget = (plotW / 5).clamp(150.0, 250.0).toDouble();
  final target = span / budget;
  for (final c in _niceSteps) {
    if (c >= target) return c;
  }
  return _niceSteps.last;
}

class Bucket {
  final Map<String, List<int>> apps = {};
  int value = 0;
}

class PresenceMark {
  const PresenceMark(this.sec, this.text, this.clientId, this.appName, this.data);

  final int sec;
  final String text;
  final String clientId;
  final String appName;
  final Map<String, dynamic> data;
}

class Session {
  Session(this.start, this.end, this.ms);

  final int start;
  final int end;
  final int ms;
}

String two(int v) => v.toString().padLeft(2, '0');

String labelAt(DateTime first, int total, num sec, {bool seconds = false, bool dateOnly = false, bool timeOnly = false}) {
  if (total <= _daySec && sec >= total) return '24:00';
  final d = first.add(Duration(seconds: sec.floor()));
  final date = '${two(d.day)}.${two(d.month)}${total > 200 * _daySec ? '.${two(d.year % 100)}' : ''}';
  if (dateOnly) return date;
  final t = '${two(d.hour)}:${two(d.minute)}${seconds ? ':${two(d.second)}' : ''}';
  if (timeOnly || total <= _daySec) return t;
  return '$date $t';
}

List<Session> sessionsOf(List<Contrib> items, String app, Metric metric) {
  final list = <Session>[];
  final mine = items.where((c) => c.app == app && c.ms > 0 && _inMetric(c.state, metric)).toList()..sort((a, b) => a.start.compareTo(b.start));
  for (final c in mine) {
    final end = c.end > c.start ? c.end : c.start + 1;
    if (list.isNotEmpty && c.start - list.last.end <= 30 && c.start >= list.last.start) {
      final p = list.last;
      list[list.length - 1] = Session(p.start, math.max(p.end, end), p.ms + c.ms);
    } else {
      list.add(Session(c.start, end, c.ms));
    }
  }
  return list;
}

bool _inMetric(int state, Metric m) {
  switch (m) {
    case Metric.focused:
      return state == 0;
    case Metric.open:
      return state == 1;
    case Metric.minimized:
      return state == 2;
    case Metric.visible:
      return state >= 0 && state <= 2;
  }
}

class _Tip {
  const _Tip({required this.visible, required this.bucket, required this.anchor, required this.interactive, required this.follow, this.detail, this.seriesId});

  final bool visible;
  final int bucket;
  final Offset anchor;
  final bool interactive;
  final bool follow;
  final String? detail;
  final String? seriesId;

  _Tip copyWith({bool? visible, int? bucket, Offset? anchor, bool? interactive, bool? follow, String? detail, bool clearDetail = false, String? seriesId, bool clearSeries = false}) => _Tip(
        visible: visible ?? this.visible,
        bucket: bucket ?? this.bucket,
        anchor: anchor ?? this.anchor,
        interactive: interactive ?? this.interactive,
        follow: follow ?? this.follow,
        detail: clearDetail ? null : (detail ?? this.detail),
        seriesId: clearSeries ? null : (seriesId ?? this.seriesId),
      );
}

class ActivityChart extends StatefulWidget {
  const ActivityChart({
    super.key,
    required this.contribs,
    required this.only,
    required this.metric,
    required this.title,
    required this.icon,
    required this.height,
    required this.first,
    required this.total,
    this.presence = const [],
    this.siteContribs = const [],
    this.onOpenSite,
    this.assetUrl,
    this.onView,
    this.series = const [],
    this.showTime = true,
    this.onPickApp,
    this.previous = const [],
    this.avgLine = false,
    this.compare = false,
  });

  final DateTime first;
  final int total;
  final List<Contrib> contribs;
  final List<PresenceMark> presence;
  final List<SiteContrib> siteContribs;
  final void Function(SiteUsage site, String? browserApp)? onOpenSite;
  final String? Function(String client, String key)? assetUrl;
  final String? only;
  final Metric metric;
  final String Function(String app) title;
  final Widget Function(String app, double size) icon;
  final double height;
  final void Function(double from, double to, int bucketSec)? onView;
  final List<ResSeries> series;
  final bool showTime;
  final void Function(String app)? onPickApp;
  final List<Contrib> previous;
  final bool avgLine;
  final bool compare;

  @override
  State<ActivityChart> createState() => _ActivityChartState();
}

class _ActivityChartState extends State<ActivityChart> {
  final key = GlobalKey();
  final tip = ValueNotifier<_Tip?>(null);
  final lineHover = ValueNotifier<String?>(null);
  OverlayEntry? entry;
  Timer? hideTimer;
  Timer? removeTimer;
  Timer? viewTimer;
  String? lastDetail;

  double vx0 = 0;
  double vx1 = _daySec.toDouble();
  List<Bucket?> cache = [];
  List<int> prevCache = [];
  List<Object?> cacheKey = [];
  int cLo = 0;
  int cHi = 0;
  double lastScale = 1;
  bool touch = false;
  bool dragging = false;
  final tipKey = GlobalKey();
  final detailKey = GlobalKey();
  final Map<int, Offset> pts = {};
  double pinchDist = 0;
  Timer? pressTimer;
  bool scrub = false;
  bool scrubbed = false;
  Offset downPos = Offset.zero;

  int bucket = 300;
  int top = 60000;
  double plotW = 1;
  double plotH = 1;

  double get span => vx1 - vx0;

  ResSeries? get focusSeries {
    final id = lineHover.value ?? seriesFocus.value;
    if (id == null) return null;
    for (final s in widget.series) {
      if (s.id == id || s.id.startsWith('$id:')) return s;
    }
    return null;
  }

  ResSeries? seriesById(String? id) {
    if (id == null) return null;
    for (final s in widget.series) {
      if (s.id == id) return s;
    }
    return null;
  }

  String? nearSeries(Offset p) {
    String? best;
    var d = widget.showTime ? 12.0 : 30.0;
    final sec = vx0 + (p.dx - _left) / plotW * span;
    for (final s in widget.series) {
      final v = seriesValueAt(s, sec);
      if (v == null) continue;
      final y = _top + plotH * (1 - v / seriesScaleTop(s, vx0, vx1));
      final dist = (y - p.dy).abs();
      if (dist < d) {
        d = dist;
        best = s.id;
      }
    }
    return best;
  }

  void setLine(String? id) {
    if (lineHover.value != id) lineHover.value = id;
  }

  @override
  void initState() {
    super.initState();
    vx1 = widget.total.toDouble();
    GestureBinding.instance.pointerRouter.addGlobalRoute(globalPointer);
    tipsReset.addListener(hideNow);
    scheduleView();
  }

  bool insideKey(GlobalKey k, Offset p) {
    final box = k.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return false;
    return (box.localToGlobal(Offset.zero) & box.size).contains(p);
  }

  void globalPointer(PointerEvent e) {
    if (e is! PointerDownEvent || tip.value == null) return;
    if (insideKey(key, e.position) || insideKey(tipKey, e.position) || insideKey(detailKey, e.position)) return;
    hideNow();
  }

  void endPress() {
    pressTimer?.cancel();
    if (scrub) {
      scrub = false;
      chartPinch.value = pts.length >= 2;
    }
  }

  void pinchMove(PointerMoveEvent e) {
    if (!pts.containsKey(e.pointer)) return;
    if (scrub) {
      show(e.localPosition, touchMode: true);
      return;
    }
    if (pressTimer != null && (e.localPosition - downPos).distance > 10) pressTimer!.cancel();
    final before = pts.values.toList();
    pts[e.pointer] = e.localPosition;
    if (pts.length < 2 || before.length < 2) return;
    final a = pts.values.elementAt(0);
    final b = pts.values.elementAt(1);
    final dist = (a - b).distance;
    final mid = Offset((a.dx + b.dx) / 2, (a.dy + b.dy) / 2);
    if (pinchDist > 8 && dist > 8) {
      final ratio = dist / pinchDist;
      setState(() {
        zoomX(ratio, vx0 + (mid.dx - _left) / plotW * span);
        clampView();
      });
      hideNow();
      scheduleView();
    }
    pinchDist = dist;
  }

  void scheduleView() {
    viewTimer?.cancel();
    viewTimer = Timer(const Duration(milliseconds: 140), () => widget.onView?.call(vx0, vx1, bucket));
  }

  String rangeText(int i) {
    final start = i * bucket;
    final end = math.min(widget.total, (i + 1) * bucket);
    if (bucket >= _daySec) {
      final a = labelAt(widget.first, widget.total, start, dateOnly: true);
      final b = labelAt(widget.first, widget.total, end - 1, dateOnly: true);
      return a == b ? a : '$a - $b';
    }
    final sec = bucket < 60;
    return '${labelAt(widget.first, widget.total, start, seconds: sec)} - ${labelAt(widget.first, widget.total, end, seconds: sec, timeOnly: true)}';
  }

  @override
  void dispose() {
    GestureBinding.instance.pointerRouter.removeGlobalRoute(globalPointer);
    tipsReset.removeListener(hideNow);
    pressTimer?.cancel();
    hideTimer?.cancel();
    removeTimer?.cancel();
    viewTimer?.cancel();
    entry?.remove();
    entry = null;
    tip.dispose();
    lineHover.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ActivityChart old) {
    super.didUpdateWidget(old);
    if (old.total != widget.total || old.first != widget.first) {
      vx0 = 0;
      vx1 = widget.total.toDouble();
      hideNow();
      scheduleView();
    }
    entry?.markNeedsBuild();
  }

  void rebuildData() {
    final total = widget.total;
    final b = bucketSecFor(span, plotW);
    bucket = b;
    final count = (total / b).ceil();
    final needLo = (vx0 / b).floor() - 1;
    final needHi = (vx1 / b).ceil() + 1;
    final sameKey = cacheKey.length == 5 &&
        identical(cacheKey[0], widget.contribs) &&
        cacheKey[1] == widget.only &&
        cacheKey[2] == widget.metric &&
        cacheKey[3] == b &&
        identical(cacheKey[4], widget.previous);
    if (sameKey && (needLo >= cLo || cLo == 0) && (needHi <= cHi || cHi >= count)) return;
    final margin = ((needHi - needLo) * 1.0).ceil();
    cLo = math.max(0, needLo - margin);
    cHi = math.min(count, needHi + margin);
    cacheKey = [widget.contribs, widget.only, widget.metric, b, widget.previous];
    final list = List<Bucket?>.filled(math.max(0, cHi - cLo), null);
    final winStart = cLo * b;
    final winEnd = cHi * b;
    for (final c in widget.contribs) {
      if (c.state < 0 || c.state > 2) continue;
      final cs = c.start;
      final ce = c.end > c.start ? c.end : c.start + 1;
      if (ce <= winStart || cs >= winEnd) continue;
      final dur = ce - cs;
      final i0 = math.max(cLo, cs ~/ b);
      final i1 = math.min(cHi - 1, (ce - 1) ~/ b);
      for (var i = i0; i <= i1; i++) {
        final ov = math.min(ce, (i + 1) * b) - math.max(cs, i * b);
        if (ov <= 0) continue;
        final share = (c.ms * ov / dur).round();
        if (share <= 0) continue;
        final bk = list[i - cLo] ??= Bucket();
        bk.apps.putIfAbsent(c.app, () => [0, 0, 0])[c.state] += share;
      }
    }
    var peak = 0;
    for (final bk in list) {
      if (bk == null) continue;
      bk.value = widget.only != null
          ? (bk.apps[widget.only] == null ? 0 : metricOf(bk.apps[widget.only]!, widget.metric))
          : bk.apps.values.fold(0, (a, v) => a + metricOf(v, widget.metric));
      if (bk.value > peak) peak = bk.value;
    }
    cache = list;
    final prevList = List<int>.filled(math.max(0, cHi - cLo), 0);
    for (final c in widget.previous) {
      if (widget.only != null && c.app != widget.only) continue;
      if (!_inMetric(c.state, widget.metric)) continue;
      final cs = c.start;
      final ce = c.end > c.start ? c.end : c.start + 1;
      if (ce <= winStart || cs >= winEnd) continue;
      final dur = ce - cs;
      final i0 = math.max(cLo, cs ~/ b);
      final i1 = math.min(cHi - 1, (ce - 1) ~/ b);
      for (var i = i0; i <= i1; i++) {
        final ov = math.min(ce, (i + 1) * b) - math.max(cs, i * b);
        if (ov > 0) prevList[i - cLo] += (c.ms * ov / dur).round();
      }
    }
    for (final v in prevList) {
      if (v > peak) peak = v;
    }
    prevCache = prevList;
    final floor = math.min(b * 1000, 60000);
    top = ((peak < floor ? floor : peak) * 1.18).ceil();
  }

  double? avgValue() {
    final maxI = (widget.total / bucket).ceil() - 1;
    final lo = ((vx0 / bucket).floor()).clamp(0, maxI).toInt();
    final hi = ((vx1 / bucket).ceil()).clamp(0, maxI).toInt();
    var sum = 0;
    var n = 0;
    for (var i = lo; i <= hi; i++) {
      final v = valueAt(i);
      if (v > 0) {
        sum += v;
        n++;
      }
    }
    return n == 0 ? null : sum / n;
  }

  Bucket? bucketOf(int i) => (i < cLo || i >= cHi) ? null : cache[i - cLo];

  int valueAt(int i) => bucketOf(i)?.value ?? 0;

  double slotCenter(int i) => (i + 0.5) * bucket;

  double xOf(double sec) => _left + (sec - vx0) / span * plotW;

  double yOf(double value) => _top + plotH * (1 - value / top);

  double lineY(double x) {
    final sec = vx0 + (x - _left) / plotW * span;
    final f = sec / bucket - 0.5;
    final i0 = f.floor();
    final t = (f - i0).clamp(0.0, 1.0).toDouble();
    final v = valueAt(i0) * (1 - t) + valueAt(i0 + 1) * t;
    return yOf(v);
  }

  void clampView() {
    final total = widget.total.toDouble();
    final s = span.clamp(math.min(_minSpan, total), total).toDouble();
    var a = vx0;
    if (a < 0) a = 0;
    if (a + s > total) a = total - s;
    vx0 = a;
    vx1 = a + s;
  }

  void zoomX(double factor, double focal) {
    final s = (span / factor).clamp(math.min(_minSpan, widget.total.toDouble()), widget.total.toDouble()).toDouble();
    final ratio = (focal - vx0) / span;
    vx0 = focal - ratio * s;
    vx1 = vx0 + s;
    clampView();
    scheduleView();
  }

  void resetView() {
    buzz(1);
    setState(() {
      vx0 = 0;
      vx1 = widget.total.toDouble();
    });
    hideNow();
    scheduleView();
  }

  int bucketAt(double dx) {
    final sec = vx0 + (dx - _left) / plotW * span;
    final maxI = (widget.total / bucket).ceil() - 1;
    return (sec / bucket).floor().clamp(0, math.max(0, maxI)).toInt();
  }

  void show(Offset local, {required bool touchMode, bool pin = false}) {
    if (cache.isEmpty) return;
    hideTimer?.cancel();
    removeTimer?.cancel();
    final box = key.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final i = bucketAt(local.dx);
    if (scrub && tip.value?.bucket != i) buzz(0);
    final Offset anchor;
    if (touchMode) {
      final y = yOf(valueAt(i).toDouble()).clamp(_top, _top + plotH).toDouble();
      anchor = box.localToGlobal(Offset(xOf(slotCenter(i)), y));
    } else {
      anchor = box.localToGlobal(local);
    }
    if (entry == null) {
      entry = OverlayEntry(builder: buildOverlay);
      Overlay.of(context).insert(entry!);
    }
    final cur = tip.value;
    final sid = (cur != null && cur.interactive && !touchMode) ? cur.seriesId : focusSeries?.id;
    final base = cur ?? _Tip(visible: true, bucket: i, anchor: anchor, interactive: touchMode, follow: !touchMode);
    tip.value = base.copyWith(
      clearSeries: sid == null,
      seriesId: sid,
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
    lineHover.value = null;
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
    if (p.dx < _left || p.dx > _left + plotW || cache.isEmpty) {
      setLine(null);
      scheduleHide();
      return;
    }
    final near = nearSeries(p);
    setLine(near);
    final lineTop = math.min(lineY(p.dx), math.min(lineY(p.dx - 8), lineY(p.dx + 8)));
    if (near != null || (widget.showTime && p.dy >= lineTop - 34 && p.dy <= _top + plotH + 6)) {
      show(p, touchMode: false);
    } else {
      scheduleHide(60);
    }
  }

  void onTapUp(TapUpDetails d) {
    if (scrubbed) {
      scrubbed = false;
      return;
    }
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
      return SelectionContainer.disabled(
        child: Listener(
          onPointerMove: pinchMove,
        onPointerUp: (e) {
          pts.remove(e.pointer);
          endPress();
          pinchDist = 0;
          chartPinch.value = pts.length >= 2;
        },
        onPointerCancel: (e) {
          pts.remove(e.pointer);
          endPress();
          pinchDist = 0;
          chartPinch.value = pts.length >= 2;
        },
        onPointerDown: (e) {
          scrubbed = false;
          if (e.kind != PointerDeviceKind.mouse) {
            pts[e.pointer] = e.localPosition;
            if (pts.length == 1) {
              downPos = e.localPosition;
              pressTimer?.cancel();
              pressTimer = Timer(const Duration(milliseconds: 350), () {
                if (pts.length != 1 || !mounted) return;
                scrub = true;
                scrubbed = true;
                chartPinch.value = true;
                buzz(2);
                show(downPos, touchMode: true);
              });
            }
            if (pts.length >= 2) {
              final a = pts.values.elementAt(0);
              final b = pts.values.elementAt(1);
              pinchDist = (a - b).distance;
              chartPinch.value = true;
            }
          }
          touch = e.kind != PointerDeviceKind.mouse;
          if (e.kind == PointerDeviceKind.mouse && e.buttons == kMiddleMouseButton) resetView();
        },
        onPointerSignal: onSignal,
        child: MouseRegion(
          cursor: dragging ? SystemMouseCursors.grabbing : SystemMouseCursors.basic,
          onHover: onHover,
          onExit: (_) {
            if (!(tip.value?.interactive ?? false)) setLine(null);
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
              if (pts.length >= 2 || scrub) return;
              final moved = d.focalPointDelta.dx != 0 || d.scale != 1;
              setState(() {
                if (d.scale != 1) {
                  zoomX(d.scale / lastScale, vx0 + (d.localFocalPoint.dx - _left) / plotW * span);
                  lastScale = d.scale;
                }
                final width = span;
                vx0 -= d.focalPointDelta.dx / plotW * width;
                vx1 = vx0 + width;
                clampView();
              });
              if (moved) {
                hideNow();
                scheduleView();
              }
            },
            child: SizedBox(
              key: key,
              width: c.maxWidth,
              height: widget.height,
              child: ClipRect(
                child: ListenableBuilder(
                  listenable: Listenable.merge([tip, lineHover, seriesFocus]),
                  builder: (context, _) {
                    final t = tip.value;
                    return CustomPaint(
                    painter: _ChartPainter(
                      series: widget.series,
                      focus: focusSeries,
                      showTime: widget.showTime,
                      buckets: cache,
                      cLo: cLo,
                      bucket: bucket,
                      first: widget.first,
                      total: widget.total,
                      vx0: vx0,
                      vx1: vx1,
                      yBottom: 0,
                      ySpan: top.toDouble(),
                      hover: t != null && t.visible ? t.bucket : null,
                      prev: widget.compare ? prevCache : const [],
                      avg: widget.avgLine ? avgValue() : null,
                    ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
        ),
      );
    });
  }

  List<SiteUsage> sitesIn(int bucketIndex, [String? appFilter]) {
    if (widget.siteContribs.isEmpty) return const [];
    final bid = appFilter != null
        ? Usage.browserIdForApp(appFilter)
        : (widget.only != null ? Usage.browserIdForApp(widget.only!) : null);
    if ((appFilter != null || widget.only != null) && bid == null) return const [];
    final a = bucketIndex * bucket;
    final b = math.min(widget.total, (bucketIndex + 1) * bucket);
    if (b <= a) return const [];
    final agg = <String, ({String browser, int ms, String title})>{};
    for (final s in widget.siteContribs) {
      if (bid != null && s.browser != bid) continue;
      final cs = s.start;
      final ce = s.end > s.start ? s.end : s.start + 1;
      if (ce <= a || cs >= b) continue;
      final ov = math.min(ce, b) - math.max(cs, a);
      if (ov <= 0) continue;
      final share = (s.ms * ov / (ce - cs)).round();
      if (share <= 0) continue;
      final key = '${s.browser}\u0000${s.domain}';
      final prev = agg[key];
      agg[key] = (
        browser: s.browser,
        ms: (prev?.ms ?? 0) + share,
        title: s.title.isNotEmpty ? s.title : (prev?.title ?? ''),
      );
    }
    final out = [
      for (final e in agg.entries)
        SiteUsage(e.value.browser, e.key.substring(e.key.indexOf('\u0000') + 1), e.value.ms, e.value.title),
    ]..sort((x, y) => y.ms.compareTo(x.ms));
    return out;
  }

  List<PresenceMark> presenceIn(int i) {
    final a = i * bucket;
    final b = (i + 1) * bucket;
    return widget.presence.where((p) => p.sec >= a && p.sec < b && p.text.isNotEmpty).take(2).toList();
  }

  Widget _presenceCard(PresenceMark m) {
    final d = m.data;
    final time = labelAt(widget.first, widget.total, m.sec, seconds: true, timeOnly: true);
    if (d.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text('$time  ${m.text}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: cOpen, fontSize: 12, fontWeight: FontWeight.w600)),
      );
    }
    String str(dynamic v) => v is String ? v : '';
    final type = d['type'] is int ? d['type'] as int : 0;
    final kinds = [tr('rpcPlaying'), tr('rpcStreaming'), tr('rpcListening'), tr('rpcWatching'), tr('rpcPlaying'), tr('rpcCompeting')];
    final kind = kinds[type >= 0 && type < kinds.length ? type : 0];
    final assets = d['assets'] is Map ? Map<String, dynamic>.from(d['assets'] as Map) : <String, dynamic>{};
    final largeKey = str(assets['large_image']);
    final smallKey = str(assets['small_image']);
    final large = largeKey.isEmpty ? null : widget.assetUrl?.call(m.clientId, largeKey);
    final small = smallKey.isEmpty ? null : widget.assetUrl?.call(m.clientId, smallKey);
    final name = m.appName.isNotEmpty ? m.appName : str(d['name']);
    var party = '';
    if (d['party'] is Map && (d['party'] as Map)['size'] is List) {
      final sz = (d['party'] as Map)['size'] as List;
      if (sz.length == 2) party = '(${sz[0]} / ${sz[1]})';
    }
    int? startSec;
    if (d['timestamps'] is Map) {
      final v = (d['timestamps'] as Map)['start'];
      if (v is int) startSec = v > 1000000000000 ? v ~/ 1000 : v;
    }
    String elapsed = '';
    if (startSec != null) {
      final now = widget.first.millisecondsSinceEpoch ~/ 1000 + m.sec;
      final e = now - startSec;
      if (e >= 0) elapsed = '${e ~/ 3600 > 0 ? '${e ~/ 3600}:' : ''}${two(e % 3600 ~/ 60)}:${two(e % 60)}';
    }
    Widget hover(String text, Widget child) => text.isEmpty ? child : Tooltip(message: text, waitDuration: const Duration(milliseconds: 250), child: child);
    final buttons = d['buttons'] is List ? (d['buttons'] as List).whereType<Map>().toList() : <Map>[];
    Widget art(String? url, double size, {double radius = 8}) => ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: url == null
              ? Container(width: size, height: size, color: cSoft, child: Icon(Icons.sports_esports, size: size * 0.5, color: cMuted))
              : Image.network(url, width: size, height: size, fit: BoxFit.cover, errorBuilder: (c, e, s) => Container(width: size, height: size, color: cSoft)),
            );
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(color: cPanel, borderRadius: BorderRadius.circular(10), border: Border.fromBorderSide(line)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(kind.toUpperCase(), style: const TextStyle(color: cMuted, fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 0.6))),
          Text(time, style: const TextStyle(color: cMuted, fontSize: 10)),
        ]),
        const SizedBox(height: 6),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            width: 52,
            height: 52,
            child: Stack(clipBehavior: Clip.none, children: [
              hover(str(assets['large_text']), art(large, 48)),
              if (small != null) Positioned(right: 0, bottom: 0, child: Container(decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: cPanel, width: 2)), child: ClipOval(child: hover(str(assets['small_text']), art(small, 20, radius: 10))))),
            ]),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (name.isNotEmpty) Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: cPrimary, fontWeight: FontWeight.w800, fontSize: 13)),
              if (str(d['details']).isNotEmpty) Text(str(d['details']), maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
              if (str(d['state']).isNotEmpty || party.isNotEmpty) Text('${str(d['state'])} $party'.trim(), maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: cMuted, fontSize: 12)),
              if (elapsed.isNotEmpty) Text(elapsed, style: const TextStyle(color: cOk, fontSize: 12, fontWeight: FontWeight.w700)),
            ]),
          ),
        ]),
        if (buttons.isNotEmpty) ...[
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final b in buttons)
              HoverBox(
                onTap: () {
                  final u = Uri.tryParse(str(b['url']));
                  if (u != null && (u.scheme == 'http' || u.scheme == 'https')) launchUrl(u);
                },
                builder: (h) => Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(color: h ? cSoft : cBg, borderRadius: BorderRadius.circular(8), border: Border.fromBorderSide(line)),
                  child: Text(str(b['label']), style: const TextStyle(color: cPrimary, fontSize: 12, fontWeight: FontWeight.w700)),
                ),
              ),
          ]),
        ],
      ]),
    );
  }

  Widget buildOverlay(BuildContext overlayContext) {
    return ListenableBuilder(
      listenable: Listenable.merge([tip, lineHover, seriesFocus]),
      builder: (context, _) {
        final t = tip.value;
        if (t == null) return const SizedBox.shrink();
        final fs = seriesById(t.seriesId);
        final fa = (t.bucket * bucket).toDouble();
        final fb = math.min(widget.total, (t.bucket + 1) * bucket).toDouble();
        final fApps = fs == null
            ? <MapEntry<String, double>>[]
            : (fs.appsIn(fa, fb).entries.where((e) => e.value > 0).toList()..sort((x, y) => y.value.compareTo(x.value)));
        final screen = MediaQuery.of(context).size;
        final b = bucketOf(t.bucket) ?? Bucket();
        final rows = b.apps.entries
            .where((e) => metricOf(e.value, widget.metric) > 0 && (widget.only == null || e.key == widget.only))
            .toList()
          ..sort((a, c) => metricOf(c.value, widget.metric).compareTo(metricOf(a.value, widget.metric)));
        final visibleRows = math.min(fs == null ? rows.length : fApps.length, 6);
        final marks = presenceIn(t.bucket);
        final maxH = math.max(120.0, screen.height - 16);
        final height = math.min(maxH, 70.0 + math.max(1, visibleRows) * 40.0 + (fs == null ? marks.length * 190.0 : 0.0));
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
                key: tipKey,
                onEnter: (_) => cancelHide(),
                onExit: (_) => scheduleHide(900),
                child: animated(pinnable(t, fs == null ? _mainTip(b, t, rows, maxH) : _seriesTip(fs, t, fApps, fa, fb, maxH)), t.visible),
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
                  key: detailKey,
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

  Widget pinnable(_Tip t, Widget child) => t.interactive
      ? DefaultSelectionStyle(
          mouseCursor: SystemMouseCursors.basic,
          child: SelectionArea(contextMenuBuilder: Platform.isAndroid ? null : copyOnlyMenu, child: child),
        )
      : child;

  BoxDecoration get _tipDecoration => BoxDecoration(
        color: cBg,
        borderRadius: BorderRadius.circular(rSm),
        border: Border.fromBorderSide(line),
        boxShadow: const [BoxShadow(color: Color(0x80000000), blurRadius: 16, offset: Offset(0, 4))],
      );

  Widget _mainTip(Bucket b, _Tip t, List<MapEntry<String, List<int>>> rows, double maxH) {
    final activeSites = sitesIn(t.bucket);
    String? browserAppFor(String bId) {
      for (final e in rows) {
        if (Usage.browserIdForApp(e.key) == bId) return e.key;
      }
      return widget.only;
    }

    return Material(
      type: MaterialType.transparency,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxH),
        child: Container(
        padding: const EdgeInsets.all(10),
        decoration: _tipDecoration,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(rangeText(t.bucket), style: const TextStyle(color: cMuted, fontSize: 12, fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text('${metricLabel(widget.metric)}: ${formatMs(b.value)}', style: const TextStyle(color: cPrimary, fontWeight: FontWeight.w900, fontSize: 15)),
          if (widget.compare && t.bucket >= cLo && t.bucket - cLo < prevCache.length)
            Text('${tr('comparePrev')}: ${formatMs(prevCache[t.bucket - cLo])}', style: const TextStyle(color: cMuted, fontSize: 12, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          if (presenceIn(t.bucket).isNotEmpty)
            Flexible(
              flex: 2,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 340),
                child: ListView(shrinkWrap: true, padding: EdgeInsets.zero, children: [for (final m in presenceIn(t.bucket)) _presenceCard(m)]),
              ),
            ),
          if (rows.isEmpty)
            Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(tr('noData'), style: const TextStyle(color: cMuted, fontSize: 12)))
          else
            Flexible(
              flex: 3,
              child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
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
            ),
          if (activeSites.isNotEmpty) ...[
            const SizedBox(height: 6),
            const Divider(height: 1, color: cBorder),
            const SizedBox(height: 6),
            Text(tr('chartSites'), style: const TextStyle(color: cMuted, fontSize: 11, fontWeight: FontWeight.w800)),
            const SizedBox(height: 3),
            for (final s in activeSites.take(4))
              HoverBox(
                onTap: t.interactive && widget.onOpenSite != null ? () => widget.onOpenSite!(s, browserAppFor(s.browser)) : null,
                builder: (h) => Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                  decoration: BoxDecoration(color: h && t.interactive ? cSoft.withValues(alpha: 0.4) : Colors.transparent, borderRadius: BorderRadius.circular(6)),
                  child: Row(children: [
                    const Icon(Icons.language, size: 13, color: cMuted),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Tooltip(
                        message: s.title.isNotEmpty ? '${s.title}\n${s.domain}' : s.domain,
                        child: Text(s.displayTitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: cPrimary, fontWeight: FontWeight.w600)),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(formatMs(s.ms), style: const TextStyle(fontSize: 11, color: cMuted)),
                  ]),
                ),
              ),
          ],
          if (!t.interactive && rows.isNotEmpty)
            Padding(padding: const EdgeInsets.only(top: 4), child: Text(tr('clickToPin'), style: const TextStyle(color: cMuted, fontSize: 11))),
        ]),
        ),
      ),
    );
  }

  Widget _seriesTip(ResSeries s, _Tip t, List<MapEntry<String, double>> apps, double a, double b, double maxH) {
    final total = s.valueIn(a, b);
    return Material(
      type: MaterialType.transparency,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxH),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: _tipDecoration,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(rangeText(t.bucket), style: const TextStyle(color: cMuted, fontSize: 12, fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text('${s.label}: ${s.format(total)}', style: TextStyle(color: s.color, fontWeight: FontWeight.w900, fontSize: 15)),
            if (apps.isNotEmpty) ...[
              const SizedBox(height: 6),
              Flexible(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 240),
                  child: ListView(
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    children: [
                      for (final e in apps)
                        HoverBox(
                          onTap: t.interactive && widget.onPickApp != null ? () => widget.onPickApp!(e.key) : null,
                          builder: (hovered) => Container(
                            height: 36,
                            margin: const EdgeInsets.only(bottom: 2),
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            decoration: BoxDecoration(
                              color: t.interactive && hovered ? cSoft.withValues(alpha: 0.5) : Colors.transparent,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(children: [
                              widget.icon(e.key, 20),
                              const SizedBox(width: 8),
                              Expanded(child: EllipsisText(widget.title(e.key), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700))),
                              const SizedBox(width: 6),
                              Text(s.format(e.value), style: const TextStyle(fontSize: 12, color: cMuted)),
                            ]),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
            if (!t.interactive && apps.isNotEmpty)
              Padding(padding: const EdgeInsets.only(top: 4), child: Text(tr('clickToPin'), style: const TextStyle(color: cMuted, fontSize: 11))),
          ]),
        ),
      ),
    );
  }

  Widget _detailTip(String app) {
    final tb = tip.value?.bucket ?? 0;
    final ws = tb * bucket;
    final we = (tb + 1) * bucket;
    final sessions = sessionsOf(widget.contribs, app, widget.metric).where((s) => s.end > ws && s.start < we).toList();
    final total = sessions.fold<int>(0, (a, s) => a + s.ms);
    final appSites = sitesIn(tb, app);
    return DefaultSelectionStyle(
      mouseCursor: SystemMouseCursors.basic,
      child: SelectionArea(
        contextMenuBuilder: Platform.isAndroid ? null : copyOnlyMenu,
        child: Material(
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
              Text('${tr('launches')}: ${sessions.length}', style: const TextStyle(color: cMuted, fontSize: 12, fontWeight: FontWeight.w700)),
              if (appSites.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(tr('chartSites'), style: const TextStyle(color: cMuted, fontSize: 12, fontWeight: FontWeight.w700)),
                const SizedBox(height: 3),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 140),
                  child: ListView(
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    children: [
                      for (final s in appSites)
                        HoverBox(
                          onTap: widget.onOpenSite != null ? () => widget.onOpenSite!(s, app) : null,
                          builder: (h) => Container(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
                            decoration: BoxDecoration(color: h ? cSoft.withValues(alpha: 0.4) : Colors.transparent, borderRadius: BorderRadius.circular(6)),
                            child: Row(children: [
                              const Icon(Icons.language, size: 13, color: cMuted),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Tooltip(
                                  message: s.title.isNotEmpty ? '${s.title}\n${s.domain}' : s.domain,
                                  child: Text(s.displayTitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: cPrimary, fontWeight: FontWeight.w600)),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(formatMs(s.ms), style: const TextStyle(fontSize: 11, color: cMuted)),
                            ]),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 6),
              Text(tr('sessions'), style: const TextStyle(color: cMuted, fontSize: 12, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 180),
                child: ListView(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  children: [
                    for (final s in sessions)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(children: [
                          Expanded(child: Text('${labelAt(widget.first, widget.total, s.start, seconds: true)} - ${labelAt(widget.first, widget.total, s.end, seconds: true, timeOnly: true)}', style: const TextStyle(fontSize: 13))),
                          Text(formatMs(s.ms), style: const TextStyle(fontSize: 12, color: cMuted)),
                        ]),
                      ),
                  ],
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _ChartPainter extends CustomPainter {
  _ChartPainter({required this.series, required this.focus, required this.showTime, required this.buckets, required this.cLo, required this.bucket, required this.first, required this.total, required this.vx0, required this.vx1, required this.yBottom, required this.ySpan, required this.hover, this.prev = const [], this.avg});

  final List<ResSeries> series;
  final ResSeries? focus;
  final bool showTime;
  final List<Bucket?> buckets;
  final int cLo;
  final int bucket;
  final DateTime first;
  final int total;
  final double vx0;
  final double vx1;
  final double yBottom;
  final double ySpan;
  final int? hover;
  final List<int> prev;
  final double? avg;

  @override
  void paint(Canvas canvas, Size size) {
    final plotW = size.width - _left - _right;
    final plotH = size.height - _top - _bottom;
    final span = vx1 - vx0;
    double xOf(double sec) => _left + (sec - vx0) / span * plotW;
    double yOf(double v) => _top + plotH * (1 - (v - yBottom) / ySpan);
    double center(int i) => (i + 0.5) * bucket;
    double valueOf(int i) => (i < cLo || i >= cLo + buckets.length ? 0 : (buckets[i - cLo]?.value ?? 0)).toDouble();

    final grid = Paint()
      ..color = cBorder
      ..strokeWidth = 1;
    const label = TextStyle(color: cMuted, fontSize: 11);
    for (var k = 0; k <= 2; k++) {
      final y = _top + plotH * k / 2;
      canvas.drawLine(Offset(_left, y), Offset(size.width - _right, y), grid);
      final f = focus ?? (!showTime && series.length == 1 ? series.first : null);
      final percent = f == null && !showTime && series.length > 1;
      final shown = percent ? '${(100 * (2 - k) / 2).round()}%' : (f == null ? formatMs((yBottom + ySpan * (2 - k) / 2).round()) : (k == 2 ? f.format(0) : f.format(seriesScaleTop(f, vx0, vx1) * (2 - k) / 2)));
      final tp = TextPainter(text: TextSpan(text: shown, style: f == null ? label : TextStyle(color: f.color, fontSize: 11, fontWeight: FontWeight.w700)), textDirection: TextDirection.ltr)..layout();
      tp.paint(canvas, Offset(math.max(0.0, _left - tp.width - 6), y - tp.height / 2));
    }
    var step = _niceSteps.last;
    final avail = size.width - _left - _right;
    for (final c in _niceSteps) {
      final yearly = total > 200 * _daySec;
      final w = c >= _daySec ? (yearly ? 66.0 : 48.0) : (c < 60 ? 62.0 : (total <= _daySec ? 46.0 : 86.0));
      if (span / c <= math.max(2.0, (avail / w).floorToDouble())) {
        step = c;
        break;
      }
    }
    final firstTick = (vx0 / step).ceil() * step;
    var lastEnd = -1000.0;
    for (var sec = firstTick; sec <= vx1; sec += step) {
      final x = xOf(sec.toDouble());
      canvas.drawLine(Offset(x, _top), Offset(x, _top + plotH), grid..color = cBorder.withValues(alpha: 0.5));
      final text = labelAt(first, total, sec, seconds: step < 60, dateOnly: step >= _daySec);
      final tp = TextPainter(text: TextSpan(text: text, style: label), textDirection: TextDirection.ltr)..layout();
      var dx = x - tp.width / 2;
      if (dx + tp.width > size.width) dx = size.width - tp.width;
      if (dx < _left - 10) dx = _left - 10;
      if (dx < lastEnd + 8) continue;
      lastEnd = dx + tp.width;
      tp.paint(canvas, Offset(dx, size.height - tp.height));
    }
    final dim = focus != null;
    final fade = dim ? 0.3 : 1.0;
    if (buckets.isEmpty || !showTime) {
      paintSeries(canvas, plotW, plotH, span);
      return;
    }

    canvas.save();
    canvas.clipRect(Rect.fromLTWH(_left, 0, plotW, _top + plotH + 1));
    final maxI = (total / bucket).ceil() - 1;
    final lo = ((vx0 / bucket).floor() - 1).clamp(0, maxI).toInt();
    final hi = ((vx1 / bucket).ceil() + 1).clamp(0, maxI).toInt();
    final pts = [for (var i = lo; i <= hi; i++) Offset(xOf(center(i)), yOf(valueOf(i)))];
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
          ..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [cPrimary.withValues(alpha: 0.28 * fade), cPrimary.withValues(alpha: 0)])
              .createShader(Rect.fromLTWH(_left, _top, plotW, plotH)),
      );
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.2
          ..strokeJoin = StrokeJoin.round
          ..color = cPrimary.withValues(alpha: fade),
      );
    }
    paintSeries(canvas, plotW, plotH, span);
    if (prev.isNotEmpty && !dim) {
      final dash = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..color = cMuted.withValues(alpha: 0.85);
      final path = Path();
      var started = false;
      for (var i = lo; i <= hi; i++) {
        final k = i - cLo;
        final v = k < 0 || k >= prev.length ? 0 : prev[k];
        final pt = Offset(xOf(center(i)), yOf(v.toDouble()));
        if (!started) {
          path.moveTo(pt.dx, pt.dy);
          started = true;
        } else {
          path.lineTo(pt.dx, pt.dy);
        }
      }
      for (final m in path.computeMetrics()) {
        var d = 0.0;
        while (d < m.length) {
          canvas.drawPath(m.extractPath(d, math.min(m.length, d + 6)), dash);
          d += 11;
        }
      }
    }
    if (avg != null && !dim) {
      final y = yOf(avg!);
      final line = Paint()
        ..strokeWidth = 1.2
        ..color = cWarn.withValues(alpha: 0.9);
      for (var x = _left; x < _left + plotW; x += 10) {
        canvas.drawLine(Offset(x, y), Offset(math.min(x + 5, _left + plotW), y), line);
      }
      final tp = TextPainter(text: TextSpan(text: '${tr('avgLine')}: ${formatMs(avg!.round())}', style: const TextStyle(color: cWarn, fontSize: 11, fontWeight: FontWeight.w700)), textDirection: TextDirection.ltr)..layout();
      tp.paint(canvas, Offset(_left + plotW - tp.width - 4, math.max(_top, y - tp.height - 2)));
    }
    if (hover != null && !dim) {
      final p = Offset(xOf(center(hover!)), yOf(valueOf(hover!)));
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

  void paintSeries(Canvas canvas, double plotW, double plotH, double span) {
    if (series.isEmpty) return;
    double xOf(double sec) => _left + (sec - vx0) / span * plotW;
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(_left, 0, plotW, _top + plotH + 1));
    final ordered = [for (final s in series) if (s.id != focus?.id) s, if (focus != null) focus!];
    for (final s in ordered) {
      final isFocus = focus != null && s.id == focus!.id;
      final top = seriesScaleTop(s, vx0, vx1);
      double yOf(double v) => _top + plotH * (1 - (v / top).clamp(0.0, 1.0));
      final pad = span * 0.2;
      final pts = [for (final p in s.points) if (p.dx >= vx0 - pad && p.dx <= vx1 + pad) Offset(xOf(p.dx), yOf(p.dy))];
      if (pts.isEmpty) continue;
      final alpha = focus == null ? 0.95 : (isFocus ? 1.0 : 0.22);
      final width = focus == null ? 2.0 : (isFocus ? 3.4 : 1.4);
      final color = s.color.withValues(alpha: alpha);
      if (pts.length == 1) {
        canvas.drawCircle(pts.first, width + 1, Paint()..color = color);
        continue;
      }
      final path = Path()..moveTo(pts.first.dx, pts.first.dy);
      for (var i = 1; i < pts.length; i++) {
        path.lineTo(pts[i].dx, pts[i].dy);
      }
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = width
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round
          ..color = color,
      );
      if (isFocus && hover != null) {
        final v = s.valueIn(hover! * bucket.toDouble(), math.min(total, (hover! + 1) * bucket).toDouble());
        final c = Offset(xOf((hover! + 0.5) * bucket), yOf(v));
        canvas.drawLine(Offset(c.dx, _top), Offset(c.dx, _top + plotH), Paint()
          ..color = s.color.withValues(alpha: 0.35)
          ..strokeWidth = 1);
        canvas.drawCircle(c, 5, Paint()..color = cBg);
        canvas.drawCircle(
            c,
            5,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2.2
              ..color = s.color);
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ChartPainter old) => true;
}
