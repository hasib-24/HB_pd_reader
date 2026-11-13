import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:pdfrx/pdfrx.dart';

import 'export.dart';
import 'models.dart';
import 'page_view.dart';
import 'updater.dart';

void main(List<String> args) {
  WidgetsFlutterBinding.ensureInitialized();
  pdfrxFlutterInitialize();
  runApp(HbApp(initial: args.isNotEmpty ? args.first : null));
}

class HbApp extends StatelessWidget {
  const HbApp({super.key, this.initial});
  final String? initial;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'HB Reader',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.blueGrey),
        home: Home(initial: initial),
      );
}

String _base(String p) => p.split(RegExp(r'[\\/]')).last;
String _stem(String p) => p.replaceFirst(RegExp(r'\.[^./\\]+$'), '');

class Home extends StatefulWidget {
  const Home({super.key, this.initial});
  final String? initial;

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  final tool = ToolState();
  final vc = ScrollController();
  final hc = ScrollController();
  Project? project;
  PdfDocument? doc;
  double zoom = 1.0;
  String? focusId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (widget.initial != null) await _openPath(widget.initial!);
      final u = await checkForUpdate();
      if (u != null && mounted) showUpdateDialog(context, u);
    });
  }

  void _msg(String t) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(t)));

  String _cur(Project pr) => (focusId != null && pr.page(focusId!) != null)
      ? focusId!
      : pr.pages.first.id;

  // ---------------- open / save ----------------
  Future<void> _pick() async {
    final r = await FilePicker.platform.pickFiles(
        type: FileType.custom, allowedExtensions: ['pdf', 'hb']);
    final p = r?.files.single.path;
    if (p != null) await _openPath(p);
  }

  Future<void> _openPath(String path) async {
    try {
      final pr = Project();
      final isHb = path.toLowerCase().endsWith('.hb');
      final sidecar = '${_stem(path)}.hb';
      Uint8List? raw;
      if (isHb) {
        pr.loadHb(await File(path).readAsBytes(), path);
      } else if (await File(sidecar).exists()) {
        pr.loadHb(await File(sidecar).readAsBytes(), sidecar);
        _msg('Loaded your saved notes');
      } else {
        raw = await File(path).readAsBytes();
      }
      final bytes = raw ?? pr.pdfBytes!;
      final d = await PdfDocument.openData(bytes);
      if (raw != null) {
        pr.initPdf(raw, _base(_stem(path)),
            [for (final p in d.pages) p.width / p.height], sidecar);
      }
      await project?.flush();
      project?.dispose();
      doc?.dispose();
      setState(() {
        project = pr;
        doc = d;
        zoom = 1;
        focusId = null;
      });
    } catch (e) {
      _msg('Could not open file: $e');
    }
  }

  Future<void> _save() async {
    final pr = project;
    if (pr == null) return;
    _msg(await pr.saveNow() ? 'Saved' : 'Save failed – use "Save .hb as…"');
  }

  Future<void> _saveAs() async {
    final pr = project;
    if (pr == null) return;
    var p = await FilePicker.platform.saveFile(
        dialogTitle: 'Save .hb file',
        fileName: '${pr.name}.hb',
        type: FileType.custom,
        allowedExtensions: ['hb']);
    if (p == null) return;
    if (!p.toLowerCase().endsWith('.hb')) p = '$p.hb';
    _msg(await pr.saveNow(p) ? 'Saved' : 'Save failed');
  }

  Future<void> _export() async {
    final pr = project, d = doc;
    if (pr == null || d == null) return;
    var dpi = 150;
    var bw = true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('Export PDF'),
          content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DropdownButton<int>(
                  value: dpi,
                  items: [
                    for (final v in [110, 150, 200, 300])
                      DropdownMenuItem(value: v, child: Text('$v DPI'))
                  ],
                  onChanged: (v) => set(() => dpi = v!),
                ),
                CheckboxListTile(
                  value: bw,
                  onChanged: (v) => set(() => bw = v!),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Black & white print mode'),
                  subtitle: const Text(
                      'Highlights become bordered boxes, pen turns black'),
                ),
              ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Export')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    var path = await FilePicker.platform.saveFile(
        dialogTitle: 'Export PDF',
        fileName: '${pr.name}-notes.pdf',
        type: FileType.custom,
        allowedExtensions: ['pdf']);
    if (path == null) return;
    if (!path.toLowerCase().endsWith('.pdf')) path = '$path.pdf';

    final prog = ValueNotifier<double>(0);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('Exporting…'),
        content: ValueListenableBuilder<double>(
          valueListenable: prog,
          builder: (_, v, __) => LinearProgressIndicator(value: v),
        ),
      ),
    );
    try {
      final bytes = await exportPdf(
          project: pr,
          doc: d,
          dpi: dpi,
          bw: bw,
          onProgress: (v) => prog.value = v);
      await File(path).writeAsBytes(bytes);
      if (mounted) Navigator.pop(context);
      _msg('Exported: ${_base(path)}');
    } catch (e) {
      if (mounted) Navigator.pop(context);
      _msg('Export failed: $e');
    }
  }

  // ---------------- notes ----------------
  Future<Uint8List?> _pickImage() async {
    final r = await FilePicker.platform
        .pickFiles(type: FileType.image, withData: true);
    final f = r?.files.single;
    if (f == null) return null;
    return f.bytes ?? (f.path != null ? await File(f.path!).readAsBytes() : null);
  }

  Future<void> _paste() async {
    final pr = project;
    if (pr == null) return;
    final id = _cur(pr);
    final img = await Pasteboard.image;
    if (img != null && img.isNotEmpty) {
      await pr.addImageSticky(id, img);
      return;
    }
    final t = await Pasteboard.text;
    if (t != null && t.trim().isNotEmpty) {
      pr.addText(id, text: t);
      return;
    }
    _msg('Clipboard has no image or text');
  }

  Future<void> _addImageFile() async {
    final pr = project;
    final b = await _pickImage();
    if (pr != null && b != null) await pr.addImageSticky(_cur(pr), b);
  }

  Future<void> _createPin(String pageId, Offset pos) async {
    final pr = project;
    if (pr == null) return;
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Attach an image to this note'),
        children: [
          SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, 'clip'),
              child: const Text('Paste from clipboard')),
          SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, 'file'),
              child: const Text('Choose image file')),
        ],
      ),
    );
    if (choice == null) return;
    final bytes = choice == 'clip' ? await Pasteboard.image : await _pickImage();
    if (bytes == null || bytes.isEmpty) {
      _msg('No image found');
      return;
    }
    pr.addPin(pageId, pos, bytes);
  }

  void _pageMenu(String v) {
    final pr = project;
    if (pr == null) return;
    final id = _cur(pr);
    if (v == 'after') pr.insertBlank(id);
    if (v == 'before') pr.insertBlank(id, before: true);
    if (v == 'delete' && !pr.deletePage(id)) {
      _msg('Only inserted blank pages can be deleted');
    }
  }

  // ---------------- UI ----------------
  @override
  Widget build(BuildContext context) {
    final pr = project;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyV, control: true): _paste,
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true): () =>
            project?.undo(),
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): _save,
        const SingleActivator(LogicalKeyboardKey.keyO, control: true): _pick,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          appBar: AppBar(
            title: Text(pr?.name ?? 'HB Reader'),
            actions: [
              IconButton(
                  tooltip: 'Open PDF / .hb  (Ctrl+O)',
                  icon: const Icon(Icons.folder_open),
                  onPressed: _pick),
              if (pr != null) ...[
                IconButton(
                    tooltip: 'Save  (Ctrl+S)',
                    icon: const Icon(Icons.save),
                    onPressed: _save),
                PopupMenuButton<String>(
                  onSelected: (v) => v == 'as' ? _saveAs() : _export(),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'as', child: Text('Save .hb as…')),
                    PopupMenuItem(value: 'pdf', child: Text('Export PDF…')),
                  ],
                ),
              ],
            ],
          ),
          body: pr == null
              ? Center(
                  child: FilledButton.icon(
                    onPressed: _pick,
                    icon: const Icon(Icons.folder_open),
                    label: const Text('Open a PDF or .hb file'),
                  ),
                )
              : Column(children: [
                  _toolbar(pr),
                  const Divider(height: 1),
                  Expanded(child: _reader(pr)),
                ]),
        ),
      ),
    );
  }

  Widget _toolbar(Project pr) {
    return ListenableBuilder(
      listenable: tool,
      builder: (context, _) => Padding(
        padding: const EdgeInsets.all(8),
        child: Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SegmentedButton<ToolMode>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                    value: ToolMode.move,
                    icon: Icon(Icons.pan_tool_alt),
                    tooltip: 'Move / scroll'),
                ButtonSegment(
                    value: ToolMode.highlight,
                    icon: Icon(Icons.highlight),
                    tooltip: 'Highlight (drag a box)'),
                ButtonSegment(
                    value: ToolMode.pen,
                    icon: Icon(Icons.edit),
                    tooltip: 'Pen'),
                ButtonSegment(
                    value: ToolMode.eraser,
                    icon: Icon(Icons.cleaning_services),
                    tooltip: 'Eraser'),
                ButtonSegment(
                    value: ToolMode.pin,
                    icon: Icon(Icons.push_pin),
                    tooltip: 'Note pin (click a spot, attach image)'),
              ],
              selected: {tool.mode},
              onSelectionChanged: (s) => tool.setMode(s.first),
            ),
            for (final c in const [0xFF000000, 0xFFD32F2F, 0xFF1976D2])
              GestureDetector(
                onTap: () {
                  tool.setColor(c);
                  tool.setMode(ToolMode.pen);
                },
                child: Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    color: Color(c),
                    shape: BoxShape.circle,
                    border: Border.all(
                        width: tool.penColor == c ? 3 : 1,
                        color: Colors.grey.shade600),
                  ),
                ),
              ),
            IconButton(
                tooltip: 'Undo  (Ctrl+Z)',
                icon: const Icon(Icons.undo),
                onPressed: pr.undo),
            IconButton(
                tooltip: 'Text sticky note',
                icon: const Icon(Icons.sticky_note_2_outlined),
                onPressed: () => pr.addText(_cur(pr))),
            IconButton(
                tooltip: 'Paste image / text as sticky  (Ctrl+V)',
                icon: const Icon(Icons.content_paste),
                onPressed: _paste),
            IconButton(
                tooltip: 'Image sticky from file',
                icon: const Icon(Icons.add_photo_alternate_outlined),
                onPressed: _addImageFile),
            PopupMenuButton<String>(
              tooltip: 'Blank pages',
              icon: const Icon(Icons.note_add_outlined),
              onSelected: _pageMenu,
              itemBuilder: (_) => const [
                PopupMenuItem(
                    value: 'after', child: Text('Insert blank page after')),
                PopupMenuItem(
                    value: 'before', child: Text('Insert blank page before')),
                PopupMenuItem(
                    value: 'delete', child: Text('Delete this blank page')),
              ],
            ),
            IconButton(
                tooltip: 'Zoom out',
                icon: const Icon(Icons.zoom_out),
                onPressed: () =>
                    setState(() => zoom = (zoom - .25).clamp(.5, 4.0))),
            Text('${(zoom * 100).round()}%'),
            IconButton(
                tooltip: 'Zoom in',
                icon: const Icon(Icons.zoom_in),
                onPressed: () =>
                    setState(() => zoom = (zoom + .25).clamp(.5, 4.0))),
          ],
        ),
      ),
    );
  }

  Widget _reader(Project pr) {
    return LayoutBuilder(builder: (context, c) {
      final pageW = (c.maxWidth - 24) * zoom;
      return ListenableBuilder(
        listenable: tool,
        builder: (context, _) {
          final scrollable = tool.mode == ToolMode.move && !tool.lockScroll;
          final physics = scrollable ? null : const NeverScrollableScrollPhysics();
          Widget list = ListenableBuilder(
            listenable: pr,
            builder: (context, _) => ListView.builder(
              controller: vc,
              physics: physics,
              padding: const EdgeInsets.all(12),
              itemCount: pr.pages.length,
              itemBuilder: (context, i) {
                final r = pr.pages[i];
                return Padding(
                  key: ValueKey(r.id),
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Column(children: [
                    Text(r.src == null ? 'Blank page · ${i + 1}' : 'Page ${i + 1}',
                        style: Theme.of(context).textTheme.labelSmall),
                    const SizedBox(height: 4),
                    PageCard(
                      project: pr,
                      tool: tool,
                      doc: doc!,
                      ref: r,
                      width: pageW,
                      onFocus: (id) => focusId = id,
                      onPin: _createPin,
                    ),
                  ]),
                );
              },
            ),
          );
          if (zoom > 1) {
            list = SingleChildScrollView(
              controller: hc,
              scrollDirection: Axis.horizontal,
              physics: physics,
              child: SizedBox(width: pageW + 24, child: list),
            );
          }
          return Listener(
            // mouse wheel still scrolls while a drawing tool is active
            onPointerSignal: (e) {
              if (e is PointerScrollEvent && !scrollable && vc.hasClients) {
                vc.jumpTo((vc.offset + e.scrollDelta.dy)
                    .clamp(0.0, vc.position.maxScrollExtent));
              }
            },
            child: list,
          );
        },
      );
    });
  }

  @override
  void dispose() {
    project?.flush();
    vc.dispose();
    hc.dispose();
    super.dispose();
  }
}
