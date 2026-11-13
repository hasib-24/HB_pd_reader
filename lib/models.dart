import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';

enum ToolMode { move, highlight, pen, eraser, pin }

class ToolState extends ChangeNotifier {
  ToolMode mode = ToolMode.move;
  int penColor = 0xFF000000;
  bool lockScroll = false; // true while a sticky note is being dragged

  void setMode(ToolMode m) {
    mode = m;
    notifyListeners();
  }

  void setColor(int c) {
    penColor = c;
    notifyListeners();
  }

  void setLock(bool v) {
    if (lockScroll == v) return;
    lockScroll = v;
    notifyListeners();
  }
}

/// One page of the reader: a PDF page (src != null) or an inserted blank page.
class PageRef {
  PageRef({required this.id, this.src, required this.aspect});
  final String id;
  final int? src; // 1-based PDF page number
  final double aspect; // width / height

  Map<String, dynamic> toJson() => {'id': id, 'src': src, 'aspect': aspect};
  factory PageRef.fromJson(Map<String, dynamic> j) => PageRef(
      id: j['id'] as String,
      src: j['src'] as int?,
      aspect: (j['aspect'] as num).toDouble());
}

enum AnnotKind { pen, highlight }

/// Pen stroke or highlight box. Points are normalized (0..1) to the page.
class Annot {
  Annot({
    required this.pageId,
    required this.kind,
    required this.color,
    required this.width,
    required this.pts,
  });
  final String pageId;
  final AnnotKind kind;
  final int color;
  final double width; // fraction of page width
  final List<Offset> pts;

  Map<String, dynamic> toJson() => {
        'pageId': pageId,
        'kind': kind.name,
        'color': color,
        'width': width,
        'pts': [
          for (final p in pts) ...[p.dx, p.dy]
        ],
      };

  factory Annot.fromJson(Map<String, dynamic> j) {
    final f = (j['pts'] as List).cast<num>();
    return Annot(
      pageId: j['pageId'] as String,
      kind: AnnotKind.values.byName(j['kind'] as String),
      color: j['color'] as int,
      width: (j['width'] as num).toDouble(),
      pts: [
        for (var i = 0; i + 1 < f.length; i += 2)
          Offset(f[i].toDouble(), f[i + 1].toDouble())
      ],
    );
  }
}

/// Sticky note on a page: text or image. Rect is normalized.
class Sticky {
  Sticky({
    required this.id,
    required this.pageId,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    this.text = '',
    this.image,
  });
  final String id;
  final String pageId;
  double x, y, w, h;
  String text;
  final String? image; // key in Project.images

  Map<String, dynamic> toJson() => {
        'id': id,
        'pageId': pageId,
        'x': x,
        'y': y,
        'w': w,
        'h': h,
        'text': text,
        'image': image,
      };
  factory Sticky.fromJson(Map<String, dynamic> j) => Sticky(
        id: j['id'] as String,
        pageId: j['pageId'] as String,
        x: (j['x'] as num).toDouble(),
        y: (j['y'] as num).toDouble(),
        w: (j['w'] as num).toDouble(),
        h: (j['h'] as num).toDouble(),
        text: (j['text'] as String?) ?? '',
        image: j['image'] as String?,
      );
}

/// Note marker: click it to see the attached image.
class Pin {
  Pin({
    required this.id,
    required this.pageId,
    required this.x,
    required this.y,
    required this.image,
  });
  final String id;
  final String pageId;
  final double x, y;
  final String image;

  Map<String, dynamic> toJson() =>
      {'id': id, 'pageId': pageId, 'x': x, 'y': y, 'image': image};
  factory Pin.fromJson(Map<String, dynamic> j) => Pin(
        id: j['id'] as String,
        pageId: j['pageId'] as String,
        x: (j['x'] as num).toDouble(),
        y: (j['y'] as num).toDouble(),
        image: j['image'] as String,
      );
}

/// Everything in one document. Saved as a `.hb` file (a zip containing the
/// original PDF, project.json and images/), so no database is needed.
class Project extends ChangeNotifier {
  Uint8List? pdfBytes;
  String name = 'document';
  String? hbPath;
  final pages = <PageRef>[];
  final annots = <Annot>[];
  final stickies = <Sticky>[];
  final pins = <Pin>[];
  final images = <String, Uint8List>{};
  Timer? _timer;

  String _id() => DateTime.now().microsecondsSinceEpoch.toRadixString(36);

  void initPdf(Uint8List bytes, String name, List<double> aspects, String hb) {
    pdfBytes = bytes;
    this.name = name;
    hbPath = hb;
    pages
      ..clear()
      ..addAll([
        for (var i = 0; i < aspects.length; i++)
          PageRef(id: 'p${i + 1}', src: i + 1, aspect: aspects[i])
      ]);
  }

  PageRef? page(String id) {
    for (final p in pages) {
      if (p.id == id) return p;
    }
    return null;
  }

  // ---------- persistence ----------
  Map<String, dynamic> toJson() => {
        'version': 1,
        'name': name,
        'pages': [for (final p in pages) p.toJson()],
        'annots': [for (final a in annots) a.toJson()],
        'stickies': [for (final s in stickies) s.toJson()],
        'pins': [for (final p in pins) p.toJson()],
      };

  Uint8List toHbBytes() {
    final a = Archive();
    void add(String n, List<int> d) => a.addFile(ArchiveFile(n, d.length, d));
    add('project.json', utf8.encode(jsonEncode(toJson())));
    add('original.pdf', pdfBytes!);
    images.forEach((k, v) => add('images/$k', v));
    final out = ZipEncoder().encode(a);
    return Uint8List.fromList(out ?? const <int>[]);
  }

  void loadHb(Uint8List bytes, String path) {
    final a = ZipDecoder().decodeBytes(bytes);
    Map<String, dynamic>? j;
    for (final f in a.files) {
      if (!f.isFile) continue;
      final d = Uint8List.fromList((f.content as List).cast<int>());
      if (f.name == 'original.pdf') {
        pdfBytes = d;
      } else if (f.name == 'project.json') {
        j = jsonDecode(utf8.decode(d)) as Map<String, dynamic>;
      } else if (f.name.startsWith('images/')) {
        images[f.name.substring(7)] = d;
      }
    }
    if (j == null || pdfBytes == null) {
      throw const FormatException('Not a valid .hb file');
    }
    name = (j['name'] as String?) ?? 'document';
    hbPath = path;
    List<T> list<T>(String k, T Function(Map<String, dynamic>) f) =>
        [for (final e in (j![k] as List? ?? const [])) f(e as Map<String, dynamic>)];
    pages
      ..clear()
      ..addAll(list('pages', PageRef.fromJson));
    annots
      ..clear()
      ..addAll(list('annots', Annot.fromJson));
    stickies
      ..clear()
      ..addAll(list('stickies', Sticky.fromJson));
    pins
      ..clear()
      ..addAll(list('pins', Pin.fromJson));
  }

  Future<bool> saveNow([String? path]) async {
    final p = path ?? hbPath;
    if (p == null || pdfBytes == null) return false;
    try {
      await File(p).writeAsBytes(toHbBytes());
      hbPath = p;
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> flush() async {
    if (_timer?.isActive ?? false) {
      _timer!.cancel();
      await saveNow();
    }
  }

  /// Live update (e.g. while dragging) – repaint only.
  void touch() => notifyListeners();

  /// Final change – repaint and schedule an autosave.
  void commit() {
    notifyListeners();
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 3), saveNow);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  // ---------- pages ----------
  void insertBlank(String refId, {bool before = false}) {
    final i = pages.indexWhere((p) => p.id == refId);
    if (i < 0) return;
    pages.insert(before ? i : i + 1,
        PageRef(id: 'b${_id()}', aspect: pages[i].aspect));
    commit();
  }

  bool deletePage(String id) {
    final p = page(id);
    if (p == null || p.src != null) return false;
    pages.remove(p);
    annots.removeWhere((a) => a.pageId == id);
    stickies.removeWhere((s) => s.pageId == id);
    pins.removeWhere((s) => s.pageId == id);
    commit();
    return true;
  }

  // ---------- drawing ----------
  void addAnnot(Annot a) {
    annots.add(a);
    commit();
  }

  void undo() {
    if (annots.isEmpty) return;
    annots.removeLast();
    commit();
  }

  void eraseAt(String pageId, Offset pos, Size s) {
    Offset px(Offset p) => Offset(p.dx * s.width, p.dy * s.height);
    final before = annots.length;
    annots.removeWhere((a) {
      if (a.pageId != pageId) return false;
      if (a.kind == AnnotKind.highlight) {
        return a.pts.length >= 2 &&
            Rect.fromPoints(px(a.pts.first), px(a.pts.last)).contains(pos);
      }
      return a.pts.any((p) => (px(p) - pos).distance < 14);
    });
    if (annots.length != before) commit();
  }

  // ---------- stickies & pins ----------
  String addImage(Uint8List bytes) {
    final n = '${_id()}.img';
    images[n] = bytes;
    return n;
  }

  void addText(String pageId, {String text = ''}) {
    stickies.add(Sticky(
        id: _id(), pageId: pageId, x: .3, y: .25, w: .35, h: .18, text: text));
    commit();
  }

  Future<void> addImageSticky(String pageId, Uint8List bytes) async {
    final ref = page(pageId);
    if (ref == null) return;
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final ar = frame.image.height / frame.image.width;
    frame.image.dispose();
    codec.dispose();
    const w = 0.4;
    final h = (w * ar * ref.aspect).clamp(0.05, 0.9).toDouble();
    stickies.add(Sticky(
        id: _id(),
        pageId: pageId,
        x: .3,
        y: .25,
        w: w,
        h: h,
        image: addImage(bytes)));
    commit();
  }

  void removeSticky(String id) {
    stickies.removeWhere((s) => s.id == id);
    commit();
  }

  void addPin(String pageId, Offset pos, Uint8List bytes) {
    pins.add(Pin(
        id: _id(),
        pageId: pageId,
        x: pos.dx,
        y: pos.dy,
        image: addImage(bytes)));
    commit();
  }

  void removePin(String id) {
    pins.removeWhere((p) => p.id == id);
    commit();
  }
}
