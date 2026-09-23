import 'dart:io';

import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class ShareEntry {
  const ShareEntry({required this.name, required this.url, required this.isDir});
  final String name;
  final String url;
  final bool isDir;
}

class ShareClient {
  static Uri? tryParseShareUrl(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;
    final withScheme = text.contains('://') ? text : 'http://$text';
    final uri = Uri.tryParse(withScheme);
    if (uri == null || uri.host.isEmpty) return null;
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    return uri.replace(
      path: uri.path.isEmpty ? '/' : uri.path,
      query: '',
      fragment: '',
    );
  }

  static Future<List<ShareEntry>> listDirectory(Uri dirUrl) async {
    final base = dirUrl.path.endsWith('/')
        ? dirUrl
        : dirUrl.replace(path: '${dirUrl.path}/');
    final resp = await http.get(base).timeout(const Duration(seconds: 8));
    if (resp.statusCode != 200) {
      throw HttpException('HTTP ${resp.statusCode}', uri: base);
    }
    final contentType = resp.headers['content-type'] ?? '';
    if (!contentType.contains('text/html') &&
        !resp.body.trimLeft().toLowerCase().startsWith('<!')) {
      final name = p.basename(base.path);
      return [
        ShareEntry(
          name: name.isEmpty ? 'download' : name,
          url: base.toString(),
          isDir: false,
        ),
      ];
    }
    final doc = html_parser.parse(resp.body);
    final out = <ShareEntry>[];
    for (final a in doc.querySelectorAll('a')) {
      final href = a.attributes['href']?.trim();
      if (href == null || href.isEmpty) continue;
      if (href == '../' || href.startsWith('?')) continue;
      final name = a.text.trim().isNotEmpty ? a.text.trim() : href;
      if (name == 'Parent Directory') continue;
      final resolved = base.resolve(href);
      final isDir = href.endsWith('/') || name.endsWith('/');
      out.add(ShareEntry(
        name: name.endsWith('/') ? name.substring(0, name.length - 1) : name,
        url: resolved.toString(),
        isDir: isDir,
      ));
    }
    out.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return out;
  }

  static Future<File> downloadFile(
    Uri fileUrl, {
    void Function(int received, int? total)? onProgress,
  }) async {
    final req = http.Request('GET', fileUrl);
    final streamed = await req.send().timeout(const Duration(seconds: 30));
    if (streamed.statusCode != 200) {
      throw HttpException('HTTP ${streamed.statusCode}', uri: fileUrl);
    }
    final total = streamed.contentLength;
    final dir =
        await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory();
    final name = p.basename(fileUrl.path).isEmpty
        ? 'download.bin'
        : p.basename(fileUrl.path);
    var path = p.join(dir.path, name);
    var i = 1;
    while (await File(path).exists()) {
      path = p.join(
        dir.path,
        '${p.basenameWithoutExtension(name)} ($i)${p.extension(name)}',
      );
      i++;
    }
    final file = File(path);
    final sink = file.openWrite();
    var received = 0;
    await for (final chunk in streamed.stream) {
      sink.add(chunk);
      received += chunk.length;
      onProgress?.call(received, total);
    }
    await sink.close();
    return file;
  }
}
