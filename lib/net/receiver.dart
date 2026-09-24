import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import '../constants.dart';
import '../models/history.dart';
import '../protocol/aes_cipher.dart';
import '../protocol/hash_sig.dart';
import '../protocol/header.dart';
import '../protocol/io_util.dart';
import '../protocol/rate_limiter.dart';

/// 日志回调。
typedef LogFn = void Function(String msg);

/// 进度回调：文件名、已传、总量、MB/s。
typedef ProgressFn = void Function(String name, int done, int total, double mbps);

/// 去掉路径穿越，只保留最后一段文件名。
String safeBasename(String? name) {
  var n = (name ?? 'unknown').replaceAll('\\', '/').split('/').last.trim();
  if (n.isEmpty || n == '.' || n == '..') return 'unknown';
  return n;
}

/// [base]/[name]，拒绝跳出 base 的路径。
String safeJoin(String base, String name) {
  final baseAbs = p.normalize(Directory(base).absolute.path);
  final pathAbs = p.normalize(p.join(baseAbs, safeBasename(name)));
  final sep = p.separator;
  if (pathAbs != baseAbs && !pathAbs.startsWith(baseAbs.endsWith(sep) ? baseAbs : '$baseAbs$sep')) {
    throw ArgumentError('非法文件名: $name');
  }
  return pathAbs;
}

enum _Result { ok, fail, skipped }

/// LANT2024 TCP 接收端：听端口、写 [saveDir]、可选续传/校验/解密。
class TransferReceiver {
  TransferReceiver({
    required this.port,
    required this.saveDir,
    required this.log,
    required this.history,
    required this.rateLimiter,
    this.resume = true,
    this.verify = true,
    this.verifyAlgo = 'md5',
    this.password = '',
    this.onProgress,
  });

  final int port;
  final String saveDir;
  final LogFn log;
  final TransferHistory history;
  final RateLimiter rateLimiter;
  final bool resume;
  final bool verify;
  final String verifyAlgo;
  final String password;
  final ProgressFn? onProgress;

  ServerSocket? _server;
  bool _stop = false;
  int completed = 0, failed = 0, skipped = 0;

  Future<void> start() async {
    _stop = false;
    completed = failed = skipped = 0;
    await Directory(saveDir).create(recursive: true);
    _server = await ServerSocket.bind(InternetAddress.anyIPv4, port);
    log('🟢 接收端监听 0.0.0.0:$port');
    _server!.listen((sock) async {
      try {
        final r = await _handle(sock);
        if (r == _Result.skipped) {
          skipped++;
        } else if (r == _Result.ok) {
          completed++;
        } else {
          failed++;
        }
      } catch (e) {
        failed++;
        log('❌ 处理失败: $e');
      } finally {
        try {
          await sock.close();
        } catch (_) {}
      }
    });
  }

  Future<void> stop() async {
    _stop = true;
    await _server?.close();
    _server = null;
    log('📊 接收统计: 成功 $completed, 跳过 $skipped, 失败 $failed');
  }

  Future<_Result> _handle(Socket sock) async {
    log('━' * 40);
    log('✅ 连接: ${sock.remoteAddress.address}:${sock.remotePort}');
    final reader = SocketReader(sock);
    try {
      final hdr = await recvProtocolHeader(reader);
      if (hdr == null) {
        log('❌ 协议头无效');
        return _Result.fail;
      }
      final ptype = hdr.$1;
      final meta = hdr.$2;
      final filename = safeBasename(meta.name);
      final logical = safeBasename(meta.logical);
      final totalSize = meta.size;
      final isDir = ptype == 'D';
      final isEncrypted = meta.encrypted;
      final savePath = safeJoin(saveDir, filename);
      final comparePath = safeJoin(
        saveDir,
        meta.sig != null && meta.sig!['tree'] == true ? logical : filename,
      );
      log(
        '📋 ${isDir ? '文件夹' : '文件'}: $filename '
        '(${(totalSize / 1024 / 1024).toStringAsFixed(1)} MB)',
      );

      if (meta.sig != null && await contentSame(comparePath, meta.sig)) {
        await _sendOffset(sock, skipOffset);
        log('⏭ 未变化，跳过: $logical');
        await history.add('接收', logical, totalSize, '跳过');
        return _Result.skipped;
      }

      var actualOffset = 0;
      if (resume && !isEncrypted && await File(savePath).exists()) {
        final existing = await File(savePath).length();
        if (existing == totalSize && totalSize > 0) {
          final algo = verify ? verifyAlgo : meta.hashAlgo;
          if (meta.hash.isNotEmpty &&
              (await calcHash(savePath, algo)).toLowerCase() ==
                  meta.hash.toLowerCase()) {
            await _sendOffset(sock, totalSize);
            log('⏭ 本地已完整且校验通过: $filename');
            await history.add('接收', filename, totalSize, '跳过', verifyResult: '通过');
            return _Result.skipped;
          }
        } else if (existing > 0 && existing < totalSize) {
          actualOffset = existing;
        }
      }

      await _sendOffset(sock, actualOffset);

      final wirePath = isEncrypted ? '$savePath.enc' : savePath;
      final wireOffset = isEncrypted ? 0 : actualOffset;
      final ok =
          await _recvPayload(reader, wirePath, wireOffset, totalSize, filename);
      if (!ok) {
        log('❌ 接收中断: $filename');
        await history.add('接收', filename, totalSize, '失败', encrypted: isEncrypted);
        return _Result.fail;
      }

      if (isEncrypted) {
        if (meta.salt.isEmpty || password.isEmpty) {
          log('❌ 缺少解密盐或密码');
          return _Result.fail;
        }
        final salt = base64.decode(meta.salt);
        final cipher = AesCipher(password, salt: Uint8List.fromList(salt));
        await cipher.decryptFile(wirePath, savePath);
        await File(wirePath).delete();
      }

      log('✅ 接收完成: $filename');
      var verifyPass = true;
      var verifyText = '';
      if (verify && meta.hash.isNotEmpty) {
        final localHash = await calcHash(savePath, verifyAlgo);
        if (localHash.toLowerCase() == meta.hash.toLowerCase()) {
          verifyText = '通过';
          log('✅ 校验通过');
        } else {
          verifyText = '失败';
          verifyPass = false;
          log('❌ 校验失败');
        }
      }

      if (isDir && verifyPass) {
        final dest = safeJoin(saveDir, logical);
        await _extractZip(savePath, dest);
        await File(savePath).delete();
        log('📦 已解压到: $logical');
      }

      await history.add(
        '接收',
        logical,
        totalSize,
        verifyPass ? '成功' : '失败',
        verifyResult: verifyText,
        encrypted: isEncrypted,
      );
      return verifyPass ? _Result.ok : _Result.fail;
    } finally {
      await reader.dispose();
    }
  }

  Future<void> _sendOffset(Socket sock, int offset) async {
    final b = BytesBuilder(copy: false);
    writeUint64BE(b, offset);
    await sendAll(sock, b.takeBytes());
  }

  Future<bool> _recvPayload(
    SocketReader reader,
    String path,
    int offset,
    int total,
    String label,
  ) async {
    var received = offset;
    var lastLog = DateTime.now();
    var lastDone = received;
    final file = File(path);
    await file.parent.create(recursive: true);
    final raf = (offset > 0 && await file.exists())
        ? await file.open(mode: FileMode.append)
        : await file.open(mode: FileMode.write);
    if (offset > 0) {
      await raf.truncate(offset);
      await raf.setPosition(offset);
    }
    try {
      while (received < total) {
        if (_stop) return false;
        final need = total - received;
        final n = need < chunkSize ? need : chunkSize;
        final data = await reader.readUpTo(n);
        if (data == null || data.isEmpty) return false;
        await raf.writeFrom(data);
        received += data.length;
        await rateLimiter.consume(data.length);
        final now = DateTime.now();
        final dt = now.difference(lastLog).inMilliseconds / 1000.0;
        if (dt >= 0.5 && total > 0) {
          final speed = (received - lastDone) / dt / 1024 / 1024;
          onProgress?.call(label, received, total, speed);
          lastLog = now;
          lastDone = received;
        }
      }
      return received >= total;
    } finally {
      await raf.close();
    }
  }
}

Future<void> _extractZip(String zipPath, String destDir) async {
  final destAbs = Directory(destDir).absolute.path;
  await Directory(destAbs).create(recursive: true);
  final input = InputFileStream(zipPath);
  try {
    final archive = ZipDecoder().decodeStream(input);
    for (final file in archive) {
      final name = file.name.replaceAll('\\', '/');
      if (name.isEmpty || name == '.') continue;
      if (name.startsWith('/') || p.isAbsolute(name)) {
        throw StateError('压缩包路径非法: ${file.name}');
      }
      final outPath = p.normalize(p.join(destAbs, name));
      if (outPath != destAbs && !p.isWithin(destAbs, outPath)) {
        throw StateError('压缩包路径非法: ${file.name}');
      }
      if (file.isSymbolicLink) {
        throw StateError('压缩包含符号链接: ${file.name}');
      }
      if (!file.isFile) {
        await Directory(outPath).create(recursive: true);
        continue;
      }
      await File(outPath).parent.create(recursive: true);
      final out = OutputFileStream(outPath);
      try {
        file.writeContent(out);
      } finally {
        await out.close();
      }
    }
  } finally {
    await input.close();
  }
}
