import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../constants.dart';

/// 局域网设备发现结果。
class DiscoveredDevice {
  DiscoveredDevice({
    required this.ip,
    required this.name,
    required this.tcpPort,
    required this.lastSeen,
  });

  final String ip;
  final String name;
  final int tcpPort;
  final DateTime lastSeen;
}

/// UDP 发现：Android 走原生 [NativeDiscovery]（DatagramSocket + MulticastLock）。
/// 非 Android 直接失败——当前客户端定位就是 Android。
class DeviceDiscovery {
  DeviceDiscovery({
    this.tcpPort = defaultPort,
    this.onFound,
    this.onChanged,
  });

  int tcpPort;
  void Function(DiscoveredDevice device)? onFound;
  void Function()? onChanged;

  static const _methods = MethodChannel('lan_transfer/discover');
  static const _events = EventChannel('lan_transfer/discover_events');

  StreamSubscription? _sub;
  bool _running = false;
  final Map<String, DiscoveredDevice> discovered = {};
  Timer? _pruneTimer;

  bool get isListening => _running;

  Future<void> start() async {
    if (_running) return;
    if (!Platform.isAndroid) {
      throw StateError('当前构建仅支持 Android 原生发现');
    }
    // 先订事件再 start，避免漏掉首批 HERE。
    _sub?.cancel();
    _sub = _events.receiveBroadcastStream().listen((raw) {
      if (raw is! Map) return;
      final ip = '${raw['ip'] ?? ''}';
      if (ip.isEmpty) return;
      final name = '${raw['name'] ?? ip}';
      final port = (raw['tcpPort'] as num?)?.toInt() ?? defaultPort;
      _remember(ip, name, port);
    });
    await _methods.invokeMethod<void>('start', {'tcpPort': tcpPort});
    _pruneTimer?.cancel();
    _pruneTimer = Timer.periodic(discoverInterval, (_) => _prune());
    _running = true;
    await probe();
  }

  Future<void> stop() async {
    _running = false;
    _pruneTimer?.cancel();
    _pruneTimer = null;
    await _sub?.cancel();
    _sub = null;
    try {
      await _methods.invokeMethod<void>('stop');
    } catch (_) {}
  }

  Future<void> ensureListening() async {
    final listening = await _methods.invokeMethod<bool>('isListening') ?? false;
    if (listening) {
      _running = true;
      return;
    }
    _running = false;
    await start();
  }

  void setTcpPort(int port) {
    if (port == tcpPort) return;
    tcpPort = port;
    unawaited(_methods.invokeMethod<void>('setTcpPort', {'tcpPort': port}));
  }

  List<DiscoveredDevice> liveDevices([DateTime? now]) {
    final t = now ?? DateTime.now();
    return discovered.values
        .where((d) => t.difference(d.lastSeen) <= discoverTtl)
        .toList()
      ..sort((a, b) => a.ip.compareTo(b.ip));
  }

  Future<void> probe() async {
    try {
      await _methods.invokeMethod<void>('probe');
    } catch (_) {}
  }

  Future<List<DiscoveredDevice>> discoverOnce() async {
    await ensureListening();
    final started = DateTime.now();
    await probe();
    await Future<void>.delayed(const Duration(milliseconds: 800));
    await probe();
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    await probe();
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    return liveDevices()
        .where(
          (d) => d.lastSeen.isAfter(
            started.subtract(const Duration(milliseconds: 500)),
          ),
        )
        .toList();
  }

  void _remember(String ip, String name, int peerPort) {
    final port = (peerPort > 0 && peerPort <= 65535) ? peerPort : defaultPort;
    final item = DiscoveredDevice(
      ip: ip,
      name: name,
      tcpPort: port,
      lastSeen: DateTime.now(),
    );
    final prev = discovered[ip];
    discovered[ip] = item;
    if (prev == null || prev.name != item.name || prev.tcpPort != item.tcpPort) {
      onFound?.call(item);
    }
    onChanged?.call();
  }

  void _prune() {
    final now = DateTime.now();
    final before = discovered.length;
    discovered.removeWhere((_, d) => now.difference(d.lastSeen) > discoverTtl);
    if (discovered.length != before) onChanged?.call();
  }
}

/// 供单元测试：与 PC 字节布局一致。
List<int> packDiscoverPacket(int kind, int tcpPort, String hostname) {
  final name = hostname.codeUnits;
  final clipped = name.length > 200 ? name.sublist(0, 200) : name;
  return [
    ...discoverMagic,
    kind & 0xff,
    (tcpPort >> 8) & 0xff,
    tcpPort & 0xff,
    ...clipped,
  ];
}

(int, int, String)? parseDiscoverPacket(List<int> data) {
  final hdr = discoverMagic.length;
  if (data.length < hdr + 3) return null;
  for (var i = 0; i < hdr; i++) {
    if (data[i] != discoverMagic[i]) return null;
  }
  final kind = data[hdr];
  final port = (data[hdr + 1] << 8) | data[hdr + 2];
  final name = String.fromCharCodes(data.sublist(hdr + 3)).trim();
  return (kind, port, name);
}
