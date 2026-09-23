import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

Future<String> calcHash(String filepath, String algo) async {
  final hash = algo == 'sha256' ? sha256 : md5;
  final digest = await hash.bind(File(filepath).openRead()).first;
  return digest.toString();
}

Future<Map<String, dynamic>> computeFileSignature(String filepath) async {
  final file = File(filepath);
  final stat = await file.stat();
  final size = stat.size;
  final raf = await file.open();
  try {
    final headLen = size < 65536 ? size : 65536;
    final head = await raf.read(headLen);
    final chunks = <List<int>>[head];
    if (size > 131072) {
      await raf.setPosition(size - 65536);
      chunks.add(await raf.read(65536));
    }
    final digest = md5.convert(chunks.expand((e) => e).toList());
    return {
      'size': size,
      'mtime': stat.modified.millisecondsSinceEpoch / 1000.0,
      'quick_hash': digest.toString(),
    };
  } finally {
    await raf.close();
  }
}

Future<bool> filesAreSame(String localPath, Map<String, dynamic>? remoteSig) async {
  if (remoteSig == null || !await File(localPath).exists()) return false;
  final local = await computeFileSignature(localPath);
  return local['size'] == remoteSig['size'] &&
      local['quick_hash'] == remoteSig['quick_hash'];
}

Future<Map<String, dynamic>> computeTreeSignature(String folder) async {
  final files = <File>[];
  await for (final e in Directory(folder).list(recursive: true, followLinks: false)) {
    if (e is File) files.add(e);
  }
  files.sort((a, b) => a.path.compareTo(b.path));
  final root = Directory(folder).absolute.path.replaceAll('\\', '/');
  final buf = BytesBuilder(copy: false);
  var total = 0;
  for (final f in files) {
    var abs = f.absolute.path.replaceAll('\\', '/');
    var rel = abs.startsWith(root) ? abs.substring(root.length) : abs;
    if (rel.startsWith('/')) rel = rel.substring(1);
    final sig = await computeFileSignature(f.path);
    total += sig['size'] as int;
    buf.add(utf8.encode('$rel:${sig['size']}:${sig['quick_hash']}\n'));
  }
  return {
    'size': total,
    'quick_hash': md5.convert(buf.takeBytes()).toString(),
    'tree': true,
  };
}

Future<bool> contentSame(String path, Map<String, dynamic>? remoteSig) async {
  if (remoteSig == null) return false;
  if (remoteSig['tree'] == true) {
    if (!await Directory(path).exists()) return false;
    final local = await computeTreeSignature(path);
    return local['quick_hash'] == remoteSig['quick_hash'];
  }
  return filesAreSame(path, remoteSig);
}
