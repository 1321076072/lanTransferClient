import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../constants.dart';

class HistoryRecord {
  HistoryRecord({
    required this.time,
    required this.direction,
    required this.filename,
    required this.size,
    required this.status,
    this.verify = '',
    this.encrypted = false,
    this.speed = '',
  });

  final String time;
  final String direction;
  final String filename;
  final int size;
  final String status;
  final String verify;
  final bool encrypted;
  final String speed;

  Map<String, dynamic> toJson() => {
        'time': time,
        'direction': direction,
        'filename': filename,
        'size': size,
        'status': status,
        'verify': verify,
        'encrypted': encrypted,
        'speed': speed,
      };

  static HistoryRecord fromJson(Map<String, dynamic> j) => HistoryRecord(
        time: (j['time'] ?? '').toString(),
        direction: (j['direction'] ?? '').toString(),
        filename: (j['filename'] ?? '').toString(),
        size: (j['size'] as num?)?.toInt() ?? 0,
        status: (j['status'] ?? '').toString(),
        verify: (j['verify'] ?? '').toString(),
        encrypted: j['encrypted'] == true,
        speed: (j['speed'] ?? '').toString(),
      );
}

class TransferHistory {
  final List<HistoryRecord> records = [];
  bool _loaded = false;

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('lan_transfer_history');
    if (raw == null || raw.isEmpty) return;
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      records
        ..clear()
        ..addAll(list.map((e) => HistoryRecord.fromJson(Map<String, dynamic>.from(e as Map))));
    } catch (_) {}
  }

  Future<void> add(
    String direction,
    String filename,
    int size,
    String status, {
    String verifyResult = '',
    bool encrypted = false,
    String speed = '',
  }) async {
    await ensureLoaded();
    records.insert(
      0,
      HistoryRecord(
        time: DateTime.now().toIso8601String().substring(0, 19).replaceFirst('T', ' '),
        direction: direction,
        filename: filename,
        size: size,
        status: status,
        verify: verifyResult,
        encrypted: encrypted,
        speed: speed,
      ),
    );
    if (records.length > historyMaxRecords) {
      records.removeRange(historyMaxRecords, records.length);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'lan_transfer_history',
      jsonEncode(records.map((e) => e.toJson()).toList()),
    );
  }

  Future<List<HistoryRecord>> getAll() async {
    await ensureLoaded();
    return List.unmodifiable(records);
  }
}
