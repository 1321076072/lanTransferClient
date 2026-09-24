import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import '../constants.dart';
import '../models/history.dart';
import '../protocol/aes_cipher.dart';
import '../protocol/hash_sig.dart';
import '../protocol/header.dart';
import '../protocol/io_util.dart';
import '../protocol/rate_limiter.dart';
import 'receiver.dart' show LogFn, ProgressFn;

/// LANT2024 TCP 发送端：连 [targetIp]:[port]，顺序发 [queue]。
class TransferSender {
  TransferSender({
    required this.targetIp,
    required this.port,
    required this.queue,
    required this.log,
    required this.history,
    required this.rateLimiter,
    this.resume = true,
    this.verify = true,
    this.verifyAlgo = 'md5',
    this.encrypt = false,
    this.password = '',
    this.sync = false,
    this.onProgress,
  });

  final String targetIp;
  final int port;
  final List<String> queue;
  final LogFn log;
  final TransferHistory history;
  final RateLimiter rateLimiter;
  final bool resume;
  final bool verify;
  final String verifyAlgo;
  final bool encrypt;
  final String password;
  final bool sync;
  final ProgressFn? onProgress;

  bool _stop = false;
  int completed = 0, failed = 0, skipped = 0;

  void requestStop() => _stop = true;

  Future<void> run() async {
    _stop = false;
    completed = failed = skipped = 0;
    final totalItems = queue.length;
    final t0 = DateTime.now();
    try {
      for (final itemPath in queue) {
        if (_stop) {
          log('⏹ 发送已停止');
          break;
        }
        final temps = <String>[];
        Socket? sock;
        try {
          if (!await File(itemPath).exists() && !await Directory(itemPath).exists()) {
            log('❌ 不存在: $itemPath');
            failed++;
            continue;
          }
          final isDir = await Directory(itemPath).exists();
          log('━' * 40);
          log('📤 队列: ${completed + skipped + failed + 1}/$totalItems');

          late String sendPath, sendName, logical, ptype;
          Map<String, dynamic>? sig;

          if (isDir) {
            final folderName = p.basename(itemPath);
            if (sync) {
              log('🔄 计算目录签名...');
              sig = await computeTreeSignature(itemPath);
            }
            final zipPath = p.join(Directory.systemTemp.path, '$folderName.zip');
            await _zipDir(itemPath, zipPath);
            temps.add(zipPath);
            sendPath = zipPath;
            sendName = '$folderName.zip';
            logical = folderName;
            ptype = 'D';
          } else {
            if (sync) sig = await computeFileSignature(itemPath);
            sendPath = itemPath;
            sendName = logical = p.basename(itemPath);
            ptype = 'F';
          }

          var fileHash = '';
          if (verify) {
            fileHash = await calcHash(sendPath, verifyAlgo);
            final preview = fileHash.length > 16 ? fileHash.substring(0, 16) : fileHash;
            log('   $verifyAlgo: $preview...');
          }

          var payload = sendPath;
          var saltB64 = '';
          if (encrypt) {
            final cipher = AesCipher(password);
            final encPath = '$sendPath.enc';
            await cipher.encryptFile(sendPath, encPath);
            temps.add(encPath);
            payload = encPath;
            saltB64 = base64.encode(cipher.salt);
          }

          final fileSize = await File(payload).length();
          log('📋 名称: $sendName (${(fileSize / 1024 / 1024).toStringAsFixed(1)} MB)');

          sock = await Socket.connect(targetIp, port, timeout: const Duration(seconds: 30));
          await sendProtocolHeader(
            sock,
            ptype,
            ProtocolMeta(
              name: sendName,
              logical: logical,
              size: fileSize,
              hash: fileHash,
              hashAlgo: verifyAlgo,
              encrypted: encrypt,
              sig: sig,
              salt: saltB64,
            ),
          );

          final reader = SocketReader(sock);
          try {
            final resp = await reader.readExact(8);
            if (resp == null) {
              log('❌ 对端未返回偏移');
              failed++;
              continue;
            }
            var resumeOffset = readUint64BE(resp);
            if (resumeOffset == skipOffset || resumeOffset >= fileSize) {
              log('⏭ 对端已有相同内容，跳过: $logical');
              skipped++;
              await history.add('发送', logical, fileSize, '跳过', encrypted: encrypt);
              continue;
            }
            if (encrypt) resumeOffset = 0;

            var sent = resumeOffset;
            var lastLog = DateTime.now();
            var lastSent = sent;
            var unflushed = 0;
            final start = DateTime.now();
            final raf = await File(payload).open();
            try {
              await raf.setPosition(resumeOffset);
              while (true) {
                if (_stop) throw StateError('已停止');
                final chunk = await raf.read(chunkSize);
                if (chunk.isEmpty) break;
                sock.add(chunk);
                unflushed += chunk.length;
                if (unflushed >= 1024 * 1024) {
                  await sock.flush();
                  unflushed = 0;
                }
                sent += chunk.length;
                await rateLimiter.consume(chunk.length);
                final now = DateTime.now();
                final dt = now.difference(lastLog).inMilliseconds / 1000.0;
                if (dt >= 0.5 && fileSize > 0) {
                  final speed = (sent - lastSent) / dt / 1024 / 1024;
                  onProgress?.call(sendName, sent, fileSize, speed);
                  lastLog = now;
                  lastSent = sent;
                }
              }
              await sock.flush();
            } finally {
              await raf.close();
            }
            final elapsed = DateTime.now().difference(start).inMilliseconds / 1000.0;
            final avg = elapsed > 0 ? fileSize / elapsed / 1024 / 1024 : 0.0;
            log('✅ 完成: $sendName (平均 ${avg.toStringAsFixed(1)} MB/s)');
            completed++;
            await history.add(
              '发送',
              sendName,
              fileSize,
              '成功',
              speed: '${avg.toStringAsFixed(1)} MB/s',
              encrypted: encrypt,
            );
          } finally {
            await reader.dispose();
          }
        } catch (e) {
          log('❌ 发送失败: $e');
          failed++;
        } finally {
          try {
            await sock?.close();
          } catch (_) {}
          for (final t in temps) {
            try {
              await File(t).delete();
            } catch (_) {}
          }
        }
      }
    } finally {
      final elapsed = DateTime.now().difference(t0).inSeconds;
      log('=' * 40);
      log('📊 发送统计: 成功 $completed/$totalItems, 跳过 $skipped, 失败 $failed');
      log('⏱ 总耗时: ${elapsed}s');
    }
  }
}

Future<void> _zipDir(String folder, String zipPath) async {
  final encoder = ZipFileEncoder();
  encoder.create(zipPath);
  await encoder.addDirectory(Directory(folder), includeDirName: false);
  encoder.close();
}
