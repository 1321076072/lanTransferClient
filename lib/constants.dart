import 'dart:typed_data';

/// LANT2024 — 必须与 PC 端传输协议字节级一致。
const String magicHeaderStr = 'LANT2024';
final Uint8List magicHeader = Uint8List.fromList(magicHeaderStr.codeUnits);

/// LANT_DISCOVER_v8 — 固定 UDP 口，与传输端口解耦。
/// 报文：magic + kind(u8) + tcp_port(u16 BE) + hostname
/// kind：0=QUERY，1=HERE（与 PC lan_transfer_gui_v7.py 一致）
const String discoverMagicStr = 'LANT_DISCOVER_v8';
final Uint8List discoverMagic = Uint8List.fromList(discoverMagicStr.codeUnits);

const int discoverKindQuery = 0;
const int discoverKindHere = 1;

const int discoverUdpPort = 5100;
const Duration discoverInterval = Duration(seconds: 3);
const Duration discoverTtl = Duration(seconds: 12);

const int defaultPort = 5000;
const int chunkSize = 65536;
const int skipOffset = 0xFFFFFFFFFFFFFFFF; // (1<<64)-1

const int pbkdf2Iterations = 100000;
const int aesKeyLen = 32;
const int aesSaltLen = 16;
const int aesIvLen = 16;
const int aesBlock = 16;

const int historyMaxRecords = 500;
