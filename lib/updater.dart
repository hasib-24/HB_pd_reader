import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// GitHub repository used for update checks.
const kRepo = 'hasib-24/HB_pd_reader';

class UpdateInfo {
  UpdateInfo(this.version, this.notes, this.assetUrl, this.pageUrl);
  final String version, notes, pageUrl;
  final String? assetUrl;
}

bool _newer(String a, String b) {
  List<int> p(String v) =>
      v.split('+').first.split('.').map((e) => int.tryParse(e) ?? 0).toList();
  final x = p(a), y = p(b);
  for (var i = 0; i < 3; i++) {
    final xi = i < x.length ? x[i] : 0, yi = i < y.length ? y[i] : 0;
    if (xi != yi) return xi > yi;
  }
  return false;
}

/// Asks GitHub for the latest release. Returns null if up to date / offline.
Future<UpdateInfo?> checkForUpdate() async {
  try {
    final current = (await PackageInfo.fromPlatform()).version;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    final req = await client
        .getUrl(Uri.parse('https://api.github.com/repos/$kRepo/releases/latest'));
    req.headers.set('Accept', 'application/vnd.github+json');
    req.headers.set('User-Agent', 'hb-reader');
    final res = await req.close();
    if (res.statusCode != 200) return null;
    final j = jsonDecode(await res.transform(utf8.decoder).join())
        as Map<String, dynamic>;
    final tag = (j['tag_name'] as String).replaceFirst(RegExp(r'^v'), '');
    if (!_newer(tag, current)) return null;
    final ext = Platform.isWindows ? '.exe' : '.AppImage';
    String? url;
    for (final a in (j['assets'] as List? ?? const [])) {
      if ((a['name'] as String).endsWith(ext)) {
        url = a['browser_download_url'] as String;
      }
    }
    return UpdateInfo(
        tag, (j['body'] as String?) ?? '', url, j['html_url'] as String);
  } catch (_) {
    return null;
  }
}

Future<void> _openUrl(String url) async {
  if (Platform.isWindows) {
    await Process.run('rundll32', ['url.dll,FileProtocolHandler', url]);
  } else {
    await Process.run('xdg-open', [url]);
  }
}

Future<void> _install(UpdateInfo u, void Function(double) progress) async {
  final client = HttpClient();
  final req = await client.getUrl(Uri.parse(u.assetUrl!));
  final res = await req.close();
  final name = u.assetUrl!.split('/').last;
  final file = File('${Directory.systemTemp.path}${Platform.pathSeparator}$name');
  final sink = file.openWrite();
  var got = 0;
  final total = res.contentLength;
  await for (final chunk in res) {
    sink.add(chunk);
    got += chunk.length;
    if (total > 0) progress(got / total);
  }
  await sink.close();

  if (Platform.isWindows) {
    // Inno Setup installer: silent upgrade, then it relaunches the app.
    await Process.start(file.path, ['/SILENT', '/NORESTART'],
        mode: ProcessStartMode.detached);
    exit(0);
  }
  final appImage = Platform.environment['APPIMAGE'];
  if (appImage != null) {
    await file.copy('$appImage.new');
    await Process.run('chmod', ['+x', '$appImage.new']);
    await File('$appImage.new').rename(appImage);
    await Process.start(appImage, [], mode: ProcessStartMode.detached);
    exit(0);
  }
  await _openUrl(u.pageUrl); // not running as AppImage: open release page
}

Future<void> showUpdateDialog(BuildContext context, UpdateInfo u) {
  var busy = false;
  var value = 0.0;
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => AlertDialog(
        title: Text('Update available: v${u.version}'),
        content: SizedBox(
          width: 420,
          child: busy
              ? Column(mainAxisSize: MainAxisSize.min, children: [
                  const Text('Downloading…'),
                  const SizedBox(height: 12),
                  LinearProgressIndicator(value: value > 0 ? value : null),
                ])
              : SingleChildScrollView(
                  child: Text(u.notes.isEmpty ? 'A new version is ready.' : u.notes)),
        ),
        actions: busy
            ? null
            : [
                TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Later')),
                FilledButton(
                  onPressed: () async {
                    if (u.assetUrl == null) {
                      await _openUrl(u.pageUrl);
                      if (ctx.mounted) Navigator.pop(ctx);
                      return;
                    }
                    set(() => busy = true);
                    try {
                      await _install(u, (v) => set(() => value = v));
                    } catch (_) {
                      if (ctx.mounted) Navigator.pop(ctx);
                      await _openUrl(u.pageUrl);
                    }
                  },
                  child: const Text('Update now'),
                ),
              ],
      ),
    ),
  );
}
