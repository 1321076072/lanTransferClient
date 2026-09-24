import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../constants.dart';
import 'io_util.dart';

/// 协议 JSON meta + magic/长度头读写。
class ProtocolMeta {
  ProtocolMeta({
    required this.name,
    required this.logical,
    required this.size,
    this.hash = '',
    this.hashAlgo = 'md5',
    this.encrypted = false,
    this.sig,
    this.salt = '',
  });

  final String name;
  final String logical;
  final int size;
  final String hash;
  final String hashAlgo;
  final bool encrypted;
  final Map<String, dynamic>? sig;
  final String salt;

  Map<String, dynamic> toJson() => {
        'name': name,
        'logical': logical,
        'size': size,
        'hash': hash,
        'hash_algo': hashAlgo,
        'encrypted': encrypted,
        'sig': sig,
        'salt': salt,
      };

  static ProtocolMeta fromJson(Map<String, dynamic> j) => ProtocolMeta(
        name: (j['name'] ?? 'unknown').toString(),
        logical: (j['logical'] ?? j['name'] ?? 'unknown').toString(),
        size: (j['size'] as num?)?.toInt() ?? 0,
        hash: (j['hash'] ?? '').toString(),
        hashAlgo: (j['hash_algo'] ?? 'md5').toString(),
        encrypted: j['encrypted'] == true,
        sig: j['sig'] is Map ? Map<String, dynamic>.from(j['sig'] as Map) : null,
        salt: (j['salt'] ?? '').toString(),
      );
}

Future<void> sendProtocolHeader(Socket sock, String ptype, ProtocolMeta meta) async {
  final metaJson = utf8.encode(jsonEncode(meta.toJson()));
  final b = BytesBuilder(copy: false);
  b.add(magicHeader);
  b.add(ptype.codeUnits); // 1 byte F|D
  writeUint32BE(b, metaJson.length);
  b.add(metaJson);
  await sendAll(sock, b.takeBytes());
}

Future<(String, ProtocolMeta)?> recvProtocolHeader(SocketReader reader) async {
  final magic = await reader.readExact(magicHeader.length);
  if (magic == null || !_bytesEq(magic, magicHeader)) return null;
  final ptypeB = await reader.readExact(1);
  final lenB = await reader.readExact(4);
  if (ptypeB == null || lenB == null) return null;
  final jsonLen = readUint32BE(lenB);
  if (jsonLen > 8 * 1024 * 1024) return null;
  final metaB = await reader.readExact(jsonLen);
  if (metaB == null) return null;
  final map = jsonDecode(utf8.decode(metaB)) as Map<String, dynamic>;
  return (String.fromCharCode(ptypeB[0]), ProtocolMeta.fromJson(map));
}

bool _bytesEq(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
