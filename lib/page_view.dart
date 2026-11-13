import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import 'models.dart';
import 'painting.dart';

/// One page in the reader: PDF render (or blank sheet) + annotation layer.
class PageCard extends StatelessWidget {
  const PageCard({
    super.key,
    required this.project,
    required this.tool,
    required this.doc,
    required this.ref,
    required this.width,
    required this.onFocus,
    required this.onPin,
  });
  final Project project;
  final ToolState tool;
  final PdfDocument doc;
  final PageRef ref;
  final double width;
  final void Function(String pageId) onFocus;
  final void Function(String pageId, Offset pos) onPin;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: AspectRatio(
        aspectRatio: ref.aspect,
        child: MouseRegion(
          onEnter: (_) => onFocus(ref.id),
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (_) => onFocus(ref.id),
            child: DecoratedBox(
              decoration: const BoxDecoration(
                color: Colors.white,
                boxShadow: [BoxShadow(blurRadius: 4, color: Colors.black38)],
              ),
              child: Stack(children: [
                if (ref.src != null)
                  Positioned.fill(
                      child: PdfPageView(document: doc, pageNumber: ref.src!)),
                Positioned.fill(
                  child: PageLayer(
                      project: project,
                      tool: tool,
                      pageId: ref.id,
                      onPin: onPin),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// Drawing (highlight/pen/eraser), sticky notes and note pins for one page.
class PageLayer extends StatefulWidget {
  const PageLayer({
    super.key,
    required this.project,
    required this.tool,
    required this.pageId,
    required this.onPin,
  });
  final Project project;
  final ToolState tool;
  final String pageId;
  final void Function(String pageId, Offset pos) onPin;

  @override
  State<PageLayer> createState() => _PageLayerState();
}

class _PageLayerState extends State<PageLayer> {
  Annot? _live;
  Offset? _down0;

  Offset _norm(Offset p, Size s) => Offset(
      (p.dx / s.width).clamp(0.0, 1.0), (p.dy / s.height).clamp(0.0, 1.0));

  void _down(PointerDownEvent e, Size s) {
    final m = widget.tool.mode;
    _down0 = e.localPosition;
    if (m == ToolMode.eraser) {
      widget.project.eraseAt(widget.pageId, e.localPosition, s);
      return;
    }
    if (m != ToolMode.pen && m != ToolMode.highlight) return;
    final hl = m == ToolMode.highlight;
    setState(() {
      _live = Annot(
        pageId: widget.pageId,
        kind: hl ? AnnotKind.highlight : AnnotKind.pen,
        color: hl ? 0x66FFEB3B : widget.tool.penColor,
        width: 0.0035,
        pts: [_norm(e.localPosition, s)],
      );
    });
  }

  void _move(PointerMoveEvent e, Size s) {
    if (widget.tool.mode == ToolMode.eraser) {
      widget.project.eraseAt(widget.pageId, e.localPosition, s);
      return;
    }
    final a = _live;
    if (a == null) return;
    setState(() {
      final p = _norm(e.localPosition, s);
      if (a.kind == AnnotKind.highlight) {
        final first = a.pts.first;
        a.pts
          ..clear()
          ..add(first)
          ..add(p);
      } else {
        a.pts.add(p);
      }
    });
  }

  void _up(PointerUpEvent e, Size s) {
    if (widget.tool.mode == ToolMode.pin) {
      final d = _down0;
      if (d != null && (e.localPosition - d).distance < 8) {
        widget.onPin(widget.pageId, _norm(e.localPosition, s));
      }
      _down0 = null;
      return;
    }
    _finish();
  }

  void _finish() {
    final a = _live;
    if (a == null) return;
    if (a.kind == AnnotKind.pen || a.pts.length >= 2) {
      widget.project.addAnnot(a);
    }
    setState(() => _live = null);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final size = Size(c.maxWidth, c.maxHeight);
      return ListenableBuilder(
        listenable: Listenable.merge([widget.project, widget.tool]),
        builder: (context, _) {
          final pr = widget.project;
          final mode = widget.tool.mode;
          final paint = CustomPaint(
            size: size,
            painter: AnnotPainter([
              ...pr.annots.where((a) => a.pageId == widget.pageId),
              if (_live != null) _live!,
            ]),
          );
          final interactive = mode == ToolMode.move;
          return Stack(clipBehavior: Clip.none, children: [
            Positioned.fill(
              child: interactive
                  ? IgnorePointer(child: paint)
                  : Listener(
                      behavior: HitTestBehavior.opaque,
                      onPointerDown: (e) => _down(e, size),
                      onPointerMove: (e) => _move(e, size),
                      onPointerUp: (e) => _up(e, size),
                      onPointerCancel: (_) => _finish(),
                      child: paint,
                    ),
            ),
            for (final s in pr.stickies.where((s) => s.pageId == widget.pageId))
              Positioned(
                key: ValueKey(s.id),
                left: s.x * size.width,
                top: s.y * size.height,
                width: s.w * size.width,
                height: s.h * size.height,
                child: IgnorePointer(
                  ignoring: !interactive,
                  child:
                      StickyBox(s: s, project: pr, tool: widget.tool, page: size),
                ),
              ),
            for (final p in pr.pins.where((p) => p.pageId == widget.pageId))
              Positioned(
                key: ValueKey(p.id),
                left: p.x * size.width - 14,
                top: p.y * size.height - 14,
                width: 28,
                height: 28,
                child: IgnorePointer(
                  ignoring: !interactive,
                  child: GestureDetector(
                    onTap: () => showPinImage(context, pr, p),
                    child: Container(
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                        border: Border.all(width: 2, color: Colors.black),
                      ),
                      child: Text('${pr.pins.indexOf(p) + 1}',
                          style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                              color: Colors.black)),
                    ),
                  ),
                ),
              ),
          ]);
        },
      );
    });
  }
}

/// Movable / resizable sticky note (text or image).
/// Sizes are relative to the page width so the note scales with zoom/export.
class StickyBox extends StatelessWidget {
  const StickyBox({
    super.key,
    required this.s,
    required this.project,
    required this.tool,
    required this.page,
  });
  final Sticky s;
  final Project project;
  final ToolState tool;
  final Size page;

  @override
  Widget build(BuildContext context) {
    final bar = page.width * 0.03;
    final pad = page.width * 0.006;
    final img = s.image == null ? null : project.images[s.image];

    void drag(PointerMoveEvent e) {
      s.x = (s.x + e.delta.dx / page.width).clamp(0.0, 1 - s.w).toDouble();
      s.y = (s.y + e.delta.dy / page.height).clamp(0.0, 1 - s.h).toDouble();
      project.touch();
    }

    void resize(PointerMoveEvent e) {
      s.w = (s.w + e.delta.dx / page.width).clamp(0.06, 1 - s.x).toDouble();
      s.h = (s.h + e.delta.dy / page.height).clamp(0.04, 1 - s.y).toDouble();
      project.touch();
    }

    void end() {
      tool.setLock(false);
      project.commit();
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        color: s.image == null ? const Color(0xFFFFF9C4) : Colors.white,
        border: Border.all(color: Colors.black87),
        boxShadow: const [BoxShadow(blurRadius: 3, color: Colors.black26)],
      ),
      child: Stack(children: [
        Positioned.fill(
          child: s.image != null
              ? (img == null
                  ? const SizedBox()
                  : Image.memory(img, fit: BoxFit.fill, gaplessPlayback: true))
              : Padding(
                  padding: EdgeInsets.only(top: bar),
                  child: TextFormField(
                    key: ValueKey('t${s.id}'),
                    initialValue: s.text,
                    maxLines: null,
                    expands: true,
                    textAlignVertical: TextAlignVertical.top,
                    style:
                        TextStyle(fontSize: page.width * 0.016, color: Colors.black),
                    decoration: InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      hintText: 'Note…',
                      contentPadding: EdgeInsets.all(pad),
                    ),
                    onTapOutside: (_) =>
                        FocusManager.instance.primaryFocus?.unfocus(),
                    onChanged: (v) {
                      s.text = v;
                      project.commit();
                    },
                  ),
                ),
        ),
        // drag bar + delete
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: bar,
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (_) => tool.setLock(true),
            onPointerMove: drag,
            onPointerUp: (_) => end(),
            onPointerCancel: (_) => end(),
            child: Container(
              color: Colors.black12,
              child: Row(children: [
                SizedBox(width: bar * .2),
                Icon(Icons.drag_indicator, size: bar * .7),
                const Spacer(),
                GestureDetector(
                  onTap: () => project.removeSticky(s.id),
                  child: Icon(Icons.close, size: bar * .7),
                ),
                SizedBox(width: bar * .2),
              ]),
            ),
          ),
        ),
        // resize handle
        Positioned(
          right: 0,
          bottom: 0,
          width: bar,
          height: bar,
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (_) => tool.setLock(true),
            onPointerMove: resize,
            onPointerUp: (_) => end(),
            onPointerCancel: (_) => end(),
            child: MouseRegion(
              cursor: SystemMouseCursors.resizeDownRight,
              child: Icon(Icons.south_east, size: bar * .8),
            ),
          ),
        ),
      ]),
    );
  }
}

Future<void> showPinImage(BuildContext context, Project pr, Pin p) {
  final bytes = pr.images[p.image];
  return showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Flexible(
          child: bytes == null
              ? const Padding(
                  padding: EdgeInsets.all(24), child: Text('Image missing'))
              : InteractiveViewer(
                  maxScale: 6, child: Image.memory(bytes, fit: BoxFit.contain)),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            TextButton.icon(
              onPressed: () {
                pr.removePin(p.id);
                Navigator.pop(ctx);
              },
              icon: const Icon(Icons.delete_outline),
              label: const Text('Delete note'),
            ),
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
          ]),
        ),
      ]),
    ),
  );
}
