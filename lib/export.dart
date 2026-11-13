import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart' as pdfl;
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart';

import 'models.dart';
import 'painting.dart';

void _text(Canvas c, String t, Offset o, double maxW, double fs,
    {bool center = false}) {
  final tp = TextPainter(
    text: TextSpan(text: t, style: TextStyle(color: Colors.black, fontSize: fs)),
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: maxW);
  tp.paint(c, center ? o - Offset(tp.width / 2, tp.height / 2) : o);
}

/// Flattens the reader (PDF pages + blank pages + all notes) into a new PDF.
/// Pages are rendered as images, so text in the *exported* copy is not
/// selectable; the .hb file keeps the original PDF untouched.
/// Note pins become numbered markers, with the images added as extra pages
/// at the end.
Future<Uint8List> exportPdf({
  required Project project,
  required PdfDocument doc,
  required int dpi,
  required bool bw,
  void Function(double)? onProgress,
}) async {
  final scale = dpi / 72.0;
  final out = pw.Document();
  final cache = <String, ui.Image>{};

  Future<ui.Image?> load(String name) async {
    if (cache.containsKey(name)) return cache[name];
    final b = project.images[name];
    if (b == null) return null;
    final codec = await ui.instantiateImageCodec(b);
    final f = await codec.getNextFrame();
    codec.dispose();
    return cache[name] = f.image;
  }

  Future<void> addPng(ui.Picture pic, int w, int h, double wPts, double hPts) async {
    final im = await pic.toImage(w, h);
    final bd = await im.toByteData(format: ui.ImageByteFormat.png);
    im.dispose();
    pic.dispose();
    final png = bd!.buffer.asUint8List();
    out.addPage(pw.Page(
      pageFormat: pdfl.PdfPageFormat(wPts, hPts),
      margin: pw.EdgeInsets.zero,
      build: (_) =>
          pw.Image(pw.MemoryImage(png), width: wPts, height: hPts, fit: pw.BoxFit.fill),
    ));
  }

  final total = project.pages.length + project.pins.length;
  var done = 0;

  for (final ref in project.pages) {
    final wPts = ref.src != null ? doc.pages[ref.src! - 1].width : 595.0;
    final hPts = wPts / ref.aspect;
    final w = (wPts * scale).round(), h = (hPts * scale).round();
    final size = Size(w.toDouble(), h.toDouble());
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    c.drawRect(Offset.zero & size, Paint()..color = Colors.white);

    if (ref.src != null) {
      final rp = await doc.pages[ref.src! - 1]
          .render(fullWidth: size.width, fullHeight: size.height);
      if (rp != null) {
        final im = await rp.createImage();
        c.drawImageRect(
          im,
          Rect.fromLTWH(0, 0, im.width.toDouble(), im.height.toDouble()),
          Offset.zero & size,
          Paint()..filterQuality = FilterQuality.high,
        );
        im.dispose();
        rp.dispose();
      }
    }

    paintAnnots(c, size, project.annots.where((a) => a.pageId == ref.id), bw: bw);

    for (final s in project.stickies.where((s) => s.pageId == ref.id)) {
      final r = Rect.fromLTWH(
          s.x * size.width, s.y * size.height, s.w * size.width, s.h * size.height);
      final im = s.image == null ? null : await load(s.image!);
      c.drawRect(
          r,
          Paint()
            ..color = (bw || im != null) ? Colors.white : const Color(0xFFFFF9C4));
      if (im != null) {
        c.drawImageRect(
          im,
          Rect.fromLTWH(0, 0, im.width.toDouble(), im.height.toDouble()),
          r,
          Paint()..filterQuality = FilterQuality.high,
        );
      } else {
        final pad = size.width * 0.006;
        c.save();
        c.clipRect(r);
        _text(c, s.text, Offset(r.left + pad, r.top + size.width * 0.03 + pad),
            r.width - pad * 2, size.width * 0.016);
        c.restore();
      }
      c.drawRect(
          r,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = size.width * 0.0015
            ..color = Colors.black87);
    }

    for (final p in project.pins.where((p) => p.pageId == ref.id)) {
      final o = Offset(p.x * size.width, p.y * size.height);
      final r = size.width * 0.014;
      c.drawCircle(o, r, Paint()..color = Colors.white);
      c.drawCircle(
          o,
          r,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = size.width * 0.0018
            ..color = Colors.black);
      _text(c, '${project.pins.indexOf(p) + 1}', o, r * 3, r * 1.2, center: true);
    }

    await addPng(rec.endRecording(), w, h, wPts, hPts);
    onProgress?.call(++done / total);
  }

  // Appendix: one page per note pin.
  for (final p in project.pins) {
    final wPts = 595.0, hPts = 842.0;
    final w = (wPts * scale).round(), h = (hPts * scale).round();
    final size = Size(w.toDouble(), h.toDouble());
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    c.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    final pageNo = project.pages.indexWhere((x) => x.id == p.pageId) + 1;
    _text(c, 'Note ${project.pins.indexOf(p) + 1}  (page $pageNo)',
        Offset(size.width * 0.05, size.width * 0.04), size.width * 0.9,
        size.width * 0.035);
    final im = await load(p.image);
    if (im != null) {
      final box = Rect.fromLTWH(size.width * 0.05, size.width * 0.12,
          size.width * 0.9, size.height - size.width * 0.17);
      final fit = applyBoxFit(BoxFit.contain,
          Size(im.width.toDouble(), im.height.toDouble()), box.size);
      final dst = Alignment.topCenter.inscribe(fit.destination, box);
      c.drawImageRect(
        im,
        Rect.fromLTWH(0, 0, im.width.toDouble(), im.height.toDouble()),
        dst,
        Paint()..filterQuality = FilterQuality.high,
      );
    }
    await addPng(rec.endRecording(), w, h, wPts, hPts);
    onProgress?.call(++done / total);
  }

  for (final im in cache.values) {
    im.dispose();
  }
  return out.save();
}
