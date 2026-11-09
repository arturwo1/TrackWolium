import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'theme.dart';

const _strokes = [
  'M 3.8 30.7 C 3.9 25.9 4.3 21.1 5.0 17.3 C 5.7 13.9 6.4 10.8 7.3 7.9 C 7.8 6.0 8.3 4.6 8.9 3.6 C 9.2 2.8 9.4 2.0 9.4 -3.8',
  'M 8.9 -3.8 C 9.1 -0.5 9.6 2.6 10.3 5.5 C 10.9 8.2 11.6 10.5 12.2 12.6 C 12.6 14.0 12.8 15.1 12.9 15.9 C 13.0 17.3 13.0 20.1 12.9 30.7',
  'M 12.9 30.7 C 12.9 26.9 13.1 23.1 13.4 19.7 C 13.8 16.6 14.4 13.8 15.2 11.4 C 15.8 9.0 16.6 7.2 17.4 5.7 C 17.9 4.6 18.2 3.6 18.6 -3.8',
  'M 18.6 -3.8 C 18.8 -0.3 19.2 3.1 19.8 6.5 C 20.4 9.4 20.8 12.6 21.1 15.3 C 21.4 17.4 21.4 19.2 21.5 30.7',
];

const _begins = [0.10, 0.18, 0.14, 0.22];
const _cycle = 2.5;
const _dash = 35.2;

Path _parse(String d) {
  final t = d.split(RegExp(r'\s+'));
  final path = Path();
  var i = 0;
  double y(String v) => 24 - double.parse(v);
  while (i < t.length) {
    if (t[i] == 'M') {
      path.moveTo(double.parse(t[i + 1]), y(t[i + 2]));
      i += 3;
    } else if (t[i] == 'C') {
      path.cubicTo(double.parse(t[i + 1]), y(t[i + 2]), double.parse(t[i + 3]), y(t[i + 4]), double.parse(t[i + 5]), y(t[i + 6]));
      i += 7;
    } else {
      i++;
    }
  }
  return path;
}

final _paths = _strokes.map(_parse).toList();
final _lengths = _paths.map((p) => p.computeMetrics().fold<double>(0, (a, m) => a + m.length)).toList();

double _phase(double t, double begin) {
  final tl = t - begin;
  if (tl < 0) return -_dash;
  if (tl < 0.45) return -_dash + _dash * Curves.easeInOutCubic.transform(tl / 0.45);
  if (tl < 1.4) return 0;
  if (tl < 1.85) return _dash * Curves.easeInOutCubic.transform((tl - 1.4) / 0.45);
  return _dash;
}

class _MarkPainter extends CustomPainter {
  _MarkPainter(this.animation) : super(repaint: animation);

  final Animation<double> animation;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24, size.height / 24);
    canvas.clipRect(const Rect.fromLTWH(0, 0, 24, 24));
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.95
      ..strokeCap = StrokeCap.round
      ..shader = ui.Gradient.linear(
        const Offset(0, 24),
        Offset.zero,
        [
          const Color(0x00FFFFFF),
          const Color(0xFFFFFFFF),
          cPrimary.withValues(alpha: 0.9),
          cPrimary.withValues(alpha: 0),
        ],
        const [0, 0.18, 0.78, 1],
      );
    final t = animation.value * _cycle;
    for (var i = 0; i < _paths.length; i++) {
      final s = _phase(t, _begins[i]);
      final start = s < 0 ? 0.0 : s;
      final end = (s + _dash) > _lengths[i] ? _lengths[i] : (s + _dash);
      if (end <= start) continue;
      final metric = _paths[i].computeMetrics().first;
      canvas.drawPath(metric.extractPath(start, end), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _MarkPainter old) => false;
}

class WoliumMark extends StatefulWidget {
  const WoliumMark({super.key, this.size = 34});

  final double size;

  @override
  State<WoliumMark> createState() => _WoliumMarkState();
}

class _WoliumMarkState extends State<WoliumMark> with SingleTickerProviderStateMixin {
  late final AnimationController controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 2500))..repeat();

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: CustomPaint(painter: _MarkPainter(controller)),
    );
  }
}
