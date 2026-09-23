import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lan_transfer_client/constants.dart';
import 'package:lan_transfer_client/net/discovery.dart';

void main() {
  test('discover v8 matches PC byte layout', () {
    final packed = packDiscoverPacket(discoverKindHere, 5001, 'DESKTOP-A');
    expect(packed.sublist(0, discoverMagic.length), discoverMagic);
    expect(packed[discoverMagic.length], discoverKindHere);
    expect(packed[discoverMagic.length + 1], 0x13);
    expect(packed[discoverMagic.length + 2], 0x89);

    final got = parseDiscoverPacket(packed)!;
    expect(got.$1, discoverKindHere);
    expect(got.$2, 5001);
    expect(got.$3, 'DESKTOP-A');
  });

  test('discover v8 query byte is zero', () {
    final packed = packDiscoverPacket(discoverKindQuery, 5000, 'phone');
    expect(packed[discoverMagic.length], 0);
    final got = parseDiscoverPacket(Uint8List.fromList(packed))!;
    expect(got.$1, discoverKindQuery);
    expect(got.$2, 5000);
    expect(got.$3, 'phone');
  });

  test('discover v8 rejects v7 magic', () {
    final v7 = [
      ...'LANT_DISCOVER_v7'.codeUnits,
      discoverKindHere,
      0x13,
      0x88,
      ...'x'.codeUnits,
    ];
    expect(parseDiscoverPacket(v7), isNull);
  });
}
