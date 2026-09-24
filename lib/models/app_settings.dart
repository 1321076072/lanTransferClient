import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../constants.dart';

/// 本地偏好：角色、端口、目标 IP、保存目录、传输选项。
class AppSettings {
  String role = 'receiver'; // receiver | sender
  int port = defaultPort;
  String targetIp = '192.168.99.1';
  String saveDir = '';
  bool resume = true;
  bool verify = true;
  String verifyAlgo = 'md5';
  bool encrypt = false;
  String password = 'lan2024';
  bool sync = false;
  double rateMbps = 0;

  static const _prefKey = 'lan_transfer_settings';

  Future<void> load() async {
    final raw = (await SharedPreferences.getInstance()).getString(_prefKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final nextRole = (j['role'] ?? role).toString();
      if (nextRole == 'receiver' || nextRole == 'sender') role = nextRole;
      final nextPort = (j['port'] as num?)?.toInt() ?? port;
      port = nextPort > 0 && nextPort <= 65535 ? nextPort : defaultPort;
      targetIp = (j['target_ip'] ?? targetIp).toString();
      saveDir = (j['save_dir'] ?? saveDir).toString();
      resume = j['resume'] != false;
      verify = j['verify'] != false;
      verifyAlgo = j['verify_algo'] == 'sha256' ? 'sha256' : 'md5';
      encrypt = j['encrypt'] == true;
      password = (j['password'] ?? password).toString();
      sync = j['sync'] == true;
      rateMbps = (j['rate_mbps'] as num?)?.toDouble() ?? rateMbps;
    } catch (_) {}
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefKey,
      jsonEncode({
        'role': role,
        'port': port,
        'target_ip': targetIp,
        'save_dir': saveDir,
        'resume': resume,
        'verify': verify,
        'verify_algo': verifyAlgo,
        'encrypt': encrypt,
        'password': password,
        'sync': sync,
        'rate_mbps': rateMbps,
      }),
    );
  }
}
