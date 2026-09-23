import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import '../constants.dart';

/// AES-CBC + PBKDF2-HMAC-SHA256，对齐 Python cryptography。
/// 文件格式：16 字节 IV + PKCS7 密文。按块读写，不把整文件放进内存。
class AesCipher {
  AesCipher(String password, {Uint8List? salt})
      : salt = salt ?? _randomBytes(aesSaltLen) {
    key = _pbkdf2(Uint8List.fromList(utf8.encode(password)), this.salt);
  }

  final Uint8List salt;
  late final Uint8List key;

  static Uint8List _pbkdf2(Uint8List password, Uint8List salt) {
    final params = Pbkdf2Parameters(salt, pbkdf2Iterations, aesKeyLen);
    final deriv = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))..init(params);
    return deriv.process(password);
  }

  static Uint8List _randomBytes(int n) {
    final r = Random.secure();
    return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
  }

  Future<void> encryptFile(String inPath, String outPath) async {
    final iv = _randomBytes(aesIvLen);
    final cipher = CBCBlockCipher(AESEngine())
      ..init(true, ParametersWithIV(KeyParameter(key), iv));
    final out = await File(outPath).open(mode: FileMode.write);
    try {
      await out.writeFrom(iv);
      var pending = Uint8List(0);
      await for (final chunk in File(inPath).openRead()) {
        pending = _concat(pending, chunk);
        final aligned = (pending.length ~/ aesBlock) * aesBlock;
        if (aligned == 0) continue;
        await out.writeFrom(_crypt(cipher, pending, aligned));
        final tail = pending.length - aligned;
        final rest = Uint8List(tail);
        rest.setRange(0, tail, pending, aligned);
        pending = rest;
      }
      final padded = _pkcs7Pad(pending);
      await out.writeFrom(_crypt(cipher, padded, padded.length));
    } finally {
      await out.close();
    }
  }

  Future<void> decryptFile(String inPath, String outPath) async {
    final input = await File(inPath).open();
    final out = await File(outPath).open(mode: FileMode.write);
    try {
      final ctLen = await input.length() - aesIvLen;
      if (ctLen < aesBlock || ctLen % aesBlock != 0) {
        throw StateError('密文长度非法');
      }
      final iv = await _readExact(input, aesIvLen);
      final cipher = CBCBlockCipher(AESEngine())
        ..init(false, ParametersWithIV(KeyParameter(key), iv));
      var left = ctLen;
      while (left > aesBlock) {
        var n = left - aesBlock;
        if (n > 65536) n = 65536;
        n -= n % aesBlock;
        await out.writeFrom(_crypt(cipher, await _readExact(input, n), n));
        left -= n;
      }
      final last = _crypt(cipher, await _readExact(input, aesBlock), aesBlock);
      await out.writeFrom(_pkcs7Unpad(last));
    } finally {
      await input.close();
      await out.close();
    }
  }
}

Uint8List _concat(Uint8List a, List<int> b) {
  if (a.isEmpty) return Uint8List.fromList(b);
  final out = Uint8List(a.length + b.length);
  out.setRange(0, a.length, a);
  out.setRange(a.length, out.length, b);
  return out;
}

Uint8List _crypt(BlockCipher cipher, Uint8List data, int length) {
  final out = Uint8List(length);
  var offset = 0;
  while (offset < length) {
    offset += cipher.processBlock(data, offset, out, offset);
  }
  return out;
}

Future<Uint8List> _readExact(RandomAccessFile raf, int n) async {
  final out = Uint8List(n);
  var got = 0;
  while (got < n) {
    final chunk = await raf.read(n - got);
    if (chunk.isEmpty) throw StateError('密文过短');
    out.setRange(got, got + chunk.length, chunk);
    got += chunk.length;
  }
  return out;
}

Uint8List _pkcs7Pad(Uint8List data) {
  final pad = aesBlock - (data.length % aesBlock);
  final out = Uint8List(data.length + pad);
  out.setRange(0, data.length, data);
  for (var i = data.length; i < out.length; i++) {
    out[i] = pad;
  }
  return out;
}

Uint8List _pkcs7Unpad(Uint8List data) {
  if (data.isEmpty) throw StateError('PKCS7 空');
  final pad = data.last;
  if (pad < 1 || pad > aesBlock || pad > data.length) {
    throw StateError('PKCS7 无效');
  }
  for (var i = data.length - pad; i < data.length; i++) {
    if (data[i] != pad) throw StateError('PKCS7 无效');
  }
  return Uint8List.sublistView(data, 0, data.length - pad);
}
