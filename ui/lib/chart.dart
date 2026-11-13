import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
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

final ValueNotifier<int> tipsReset = ValueNotifier<int>(0);
final ValueNotifier<bool> chartPinch = ValueNotifier<bool>(false);

const _daySec = 86400;
const _niceSteps = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200, 10800, 21600, 43200, 86400, 172800, 604800, 2592000];
const _minSpan = 30.0;
const _left = 42.0;
const _right = 10.0;
const _top = 8.0;
const _bottom = 22.0;
const _tipWidth = 250.0;
const _detailWidth = 250.0;

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
    required this.contribs,
    required this.only,
    required this.metric,
    required this.title,
    required this.icon,
    required this.height,
    required this.first,
    required this.total,
    this.presence = const [],
    this.assetUrl,
    this.onView,
  });

  final DateTime first;
  final int total;
  final List<Contrib> contribs;
  final List<PresenceMark> presence;
  final String? Function(String client, String key)? assetUrl;
  final String? only;
  final Metric metric;
  final String Function(String app) title;
  final Widget Function(String app, double size) icon;
  final double height;
  final void Function(double from, double to, int bucketSec)? onView;

  @override
  State<ActivityChart> createState() => _ActivityChartState();
}

class _ActivityChartState extends State<ActivityChart> {
  final key = GlobalKey();
  final tip = ValueNotifier<_Tip?>(null);
  OverlayEntry? entry;
  Timer? hideTimer;
  Timer? removeTimer;
  Timer? viewTimer;
  String? lastDetail;

  double vx0 = 0;
  double vx1 = _daySec.toDouble();
  List<Bucket?> cache = [];
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

  int bucket = 300;
  int top = 60000;
  double plotW = 1;
  double plotH = 1;

  double get span => vx1 - vx0;

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

  void pinchMove(PointerMoveEvent e) {
    if (!pts.containsKey(e.pointer)) return;
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
    hideTimer?.cancel();
    removeTimer?.cancel();
    viewTimer?.cancel();
    entry?.remove();
    entry = null;
    tip.dispose();
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
    final sameKey = cacheKey.length == 4 &&
        identical(cacheKey[0], widget.contribs) &&
        cacheKey[1] == widget.only &&
        cacheKey[2] == widget.metric &&
        cacheKey[3] == b;
    if (sameKey && (needLo >= cLo || cLo == 0) && (needHi <= cHi || cHi >= count)) return;
    final margin = ((needHi - needLo) * 1.0).ceil();
    cLo = math.max(0, needLo - margin);
    cHi = math.min(count, needHi + margin);
    cacheKey = [widget.contribs, widget.only, widget.metric, b];
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
    final floor = math.min(b * 1000, 60000);
    top = ((peak < floor ? floor : peak) * 1.18).ceil();
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
    if (p.dx < _left || p.dx > _left + plotW || cache.isEmpty) {
      scheduleHide();
      return;
    }
    final lineTop = math.min(lineY(p.dx), math.min(lineY(p.dx - 8), lineY(p.dx + 8)));
    if (p.dy >= lineTop - 34 && p.dy <= _top + plotH + 6) {
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
        onPointerMove: pinchMove,
        onPointerUp: (e) {
          pts.remove(e.pointer);
          pinchDist = 0;
          chartPinch.value = pts.length >= 2;
        },
        onPointerCancel: (e) {
          pts.remove(e.pointer);
          pinchDist = 0;
          chartPinch.value = pts.length >= 2;
        },
        onPointerDown: (e) {
          if (e.kind != PointerDeviceKind.mouse) {
            pts[e.pointer] = e.localPosition;
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
              if (pts.length >= 2) return;
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
                child: ValueListenableBuilder<_Tip?>(
                  valueListenable: tip,
                  builder: (context, t, _) => CustomPaint(
                    painter: _ChartPainter(
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
              art(large, 48),
              if (small != null) Positioned(right: 0, bottom: 0, child: Container(decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: cPanel, width: 2)), child: ClipOval(child: art(small, 20, radius: 10)))),
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
    return ValueListenableBuilder<_Tip?>(
      valueListenable: tip,
      builder: (context, t, _) {
        if (t == null) return const SizedBox.shrink();
        final screen = MediaQuery.of(context).size;
        final b = bucketOf(t.bucket) ?? Bucket();
        final rows = b.apps.entries
            .where((e) => metricOf(e.value, widget.metric) > 0 && (widget.only == null || e.key == widget.only))
            .toList()
          ..sort((a, c) => metricOf(c.value, widget.metric).compareTo(metricOf(a.value, widget.metric)));
        final visibleRows = math.min(rows.length, 6);
        final marks = presenceIn(t.bucket);
        final height = 70.0 + math.max(1, visibleRows) * 40.0 + marks.length * 150.0;
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
          Text(rangeText(t.bucket), style: const TextStyle(color: cMuted, fontSize: 12, fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text('${metricLabel(widget.metric)}: ${formatMs(b.value)}', style: const TextStyle(color: cPrimary, fontWeight: FontWeight.w900, fontSize: 15)),
          const SizedBox(height: 6),
          for (final m in presenceIn(t.bucket)) _presenceCard(m),
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
    final tb = tip.value?.bucket ?? 0;
    final ws = tb * bucket;
    final we = (tb + 1) * bucket;
    final sessions = sessionsOf(widget.contribs, app, widget.metric).where((s) => s.end > ws && s.start < we).toList();
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
                      Expanded(child: Text('${labelAt(widget.first, widget.total, s.start, seconds: true)} - ${labelAt(widget.first, widget.total, s.end, seconds: true, timeOnly: true)}', style: const TextStyle(fontSize: 13))),
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
  _ChartPainter({required this.buckets, required this.cLo, required this.bucket, required this.first, required this.total, required this.vx0, required this.vx1, required this.yBottom, required this.ySpan, required this.hover});

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
      final v = yBottom + ySpan * (2 - k) / 2;
      final tp = TextPainter(text: TextSpan(text: formatMs(v.round()), style: label), textDirection: TextDirection.ltr)..layout();
      tp.paint(canvas, Offset(_left - tp.width - 6, y - tp.height / 2));
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
    for (var sec = firstTick; sec <= vx1; sec += step) {
      final x = xOf(sec.toDouble());
      canvas.drawLine(Offset(x, _top), Offset(x, _top + plotH), grid..color = cBorder.withValues(alpha: 0.5));
      final text = labelAt(first, total, sec, seconds: step < 60, dateOnly: step >= _daySec);
      final tp = TextPainter(text: TextSpan(text: text, style: label), textDirection: TextDirection.ltr)..layout();
      var dx = x - tp.width / 2;
      if (dx + tp.width > size.width) dx = size.width - tp.width;
      if (dx < _left - 10) dx = _left - 10;
      tp.paint(canvas, Offset(dx, size.height - tp.height));
    }
    if (buckets.isEmpty) return;

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
    if (hover != null) {
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

  @override
  bool shouldRepaint(covariant _ChartPainter old) => true;
}
