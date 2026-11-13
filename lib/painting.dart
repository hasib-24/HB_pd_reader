import 'package:flutter/material.dart';
import 'models.dart';

/// Paints pen strokes and highlights. Shared by the screen and the exporter.
/// [bw] = print mode: highlights become bordered boxes, pen becomes black.
void paintAnnots(Canvas c, Size s, Iterable<Annot> items, {bool bw = false}) {
  Offset px(Offset p) => Offset(p.dx * s.width, p.dy * s.height);
  for (final a in items) {
    if (a.pts.isEmpty) continue;
    if (a.kind == AnnotKind.highlight) {
      if (a.pts.length < 2) continue;
      final r = Rect.fromPoints(px(a.pts.first), px(a.pts.last));
      if (bw) {
        c.drawRect(
            r,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = s.width * 0.0025
              ..color = Colors.black);
      } else {
        c.drawRect(r, Paint()..color = Color(a.color));
      }
    } else {
      final p = Paint()
        ..color = bw ? Colors.black : Color(a.color)
        ..style = PaintingStyle.stroke
        ..strokeWidth = a.width * s.width
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      if (a.pts.length == 1) {
        c.drawCircle(px(a.pts.first), p.strokeWidth / 2,
            p..style = PaintingStyle.fill);
        continue;
      }
      final path = Path()..moveTo(px(a.pts.first).dx, px(a.pts.first).dy);
      for (final q in a.pts.skip(1)) {
        path.lineTo(px(q).dx, px(q).dy);
      }
      c.drawPath(path, p);
    }
  }
}

class AnnotPainter extends CustomPainter {
  AnnotPainter(this.items);
  final List<Annot> items;

  @override
  void paint(Canvas canvas, Size size) => paintAnnots(canvas, size, items);

  @override
  bool shouldRepaint(covariant AnnotPainter old) => true;
}
