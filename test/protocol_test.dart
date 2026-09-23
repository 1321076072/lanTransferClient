import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lan_transfer_client/constants.dart';
import 'package:lan_transfer_client/protocol/aes_cipher.dart';
import 'package:lan_transfer_client/protocol/header.dart';
import 'package:lan_transfer_client/protocol/io_util.dart';

void main() {
  test('uint64 skip offset roundtrip', () {
    final b = BytesBuilder(copy: false);
    writeUint64BE(b, skipOffset);
    final bytes = b.takeBytes();
    expect(bytes, Uint8List.fromList(List.filled(8, 0xff)));
    expect(readUint64BE(bytes), skipOffset);
  });

  test('protocol header roundtrip', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final got = server.first.then((sock) async {
      final reader = SocketReader(sock);
      try {
        return await recvProtocolHeader(reader);
      } finally {
        await reader.dispose();
        await sock.close();
      }
    });
    final sock = await Socket.connect(InternetAddress.loopbackIPv4, server.port);
    await sendProtocolHeader(
      sock,
      'D',
      ProtocolMeta(
        name: 'dir.zip',
        logical: 'dir',
        size: 42,
        hash: 'abc',
        hashAlgo: 'sha256',
        encrypted: true,
        sig: {'tree': true, 'quick_hash': 'zz', 'size': 10},
        salt: 'c2FsdA==',
      ),
    );
    final hdr = await got.timeout(const Duration(seconds: 2));
    await sock.close();
    await server.close();
    expect(hdr, isNotNull);
    expect(hdr!.$1, 'D');
    expect(hdr.$2.logical, 'dir');
    expect(hdr.$2.size, 42);
    expect(hdr.$2.hashAlgo, 'sha256');
    expect(hdr.$2.encrypted, isTrue);
    expect(hdr.$2.sig?['tree'], isTrue);
    expect(hdr.$2.salt, 'c2FsdA==');
  });

  test('socket reader keeps bytes across slices', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final got = server.first.then((sock) async {
      final reader = SocketReader(sock);
      try {
        final head = await reader.readExact(4);
        final tail = await reader.readExact(6);
        return [head, tail];
      } finally {
        await reader.dispose();
        await sock.close();
      }
    });
    final sock = await Socket.connect(InternetAddress.loopbackIPv4, server.port);
    sock.add(const [0, 1, 2, 3]);
    await sock.flush();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    sock.add(const [4, 5, 6, 7, 8, 9]);
    await sock.flush();
    final parts = await got.timeout(const Duration(seconds: 2));
    await sock.close();
    await server.close();
    expect(parts[0], [0, 1, 2, 3]);
    expect(parts[1], [4, 5, 6, 7, 8, 9]);
  });

  test('aes streams any length', () async {
    final cipher = AesCipher('lan2024');
    final other = AesCipher('lan2024', salt: cipher.salt);
    final dir = await Directory.systemTemp.createTemp('lant_aes_');
    try {
      for (final n in [0, 1, 15, 16, 17, 4097, 100000]) {
        final data = Uint8List(n);
        for (var i = 0; i < n; i++) {
          data[i] = i & 0xff;
        }
        final src = File('${dir.path}/$n.bin');
        final enc = File('${dir.path}/$n.enc');
        final dec = File('${dir.path}/$n.out');
        await src.writeAsBytes(data);
        await cipher.encryptFile(src.path, enc.path);
        await (n == 17 ? other : cipher).decryptFile(enc.path, dec.path);
        expect(await dec.readAsBytes(), data, reason: 'len=$n');
        expect(await enc.length(), aesIvLen + ((n ~/ aesBlock) + 1) * aesBlock);
      }
    } finally {
      await dir.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
