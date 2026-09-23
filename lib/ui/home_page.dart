import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../constants.dart';
import '../http_share/share_client.dart';
import '../models/app_settings.dart';
import '../models/history.dart';
import '../net/discovery.dart';
import '../net/receiver.dart';
import '../net/sender.dart';
import '../protocol/rate_limiter.dart';
import 'browser_page.dart';
import 'history_page.dart';
import 'scan_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _settings = AppSettings();
  final _history = TransferHistory();
  final _logs = ValueNotifier<List<String>>(const []);
  final _queue = <String>[];
  final _rate = RateLimiter(0);
  final _portCtrl = TextEditingController(text: '$defaultPort');
  final _targetCtrl = TextEditingController(text: '192.168.99.1');
  final _passwordCtrl = TextEditingController(text: 'lan2024');
  final _httpUrlCtrl = TextEditingController();

  DeviceDiscovery? _discovery;
  TransferReceiver? _receiver;
  TransferSender? _sender;
  bool _busy = false;
  bool _ready = false;
  String _localIp = '获取中…';
  String _progress = '';
  double? _ratio;
  List<DiscoveredDevice> _devices = [];

  @override
  void initState() {
    super.initState();
    // 先出第一帧，再做 prefs / 网络。
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  Future<void> _bootstrap() async {
    await _settings.load();
    if (!mounted) return;
    _portCtrl.text = '${_settings.port}';
    _targetCtrl.text = _settings.targetIp;
    _passwordCtrl.text = _settings.password;
    _rate.updateLimit(_settings.rateMbps);
    setState(() => _ready = true);

    unawaited(_ensureSaveDir());
    unawaited(_resolveLocalIp());
    unawaited(_startDiscovery());
  }

  Future<void> _ensureSaveDir() async {
    if (_settings.saveDir.isEmpty) {
      final docs = await getApplicationDocumentsDirectory();
      if (!mounted) return;
      _settings.saveDir = '${docs.path}/LanTransfer';
      await _settings.save();
      if (mounted) setState(() {});
    }
    try {
      await Directory(_settings.saveDir).create(recursive: true);
    } catch (_) {}
  }

  Future<void> _resolveLocalIp() async {
    try {
      final ip = await NetworkInfo().getWifiIP();
      if (!mounted) return;
      setState(() => _localIp = ip ?? '未知');
    } catch (_) {
      if (mounted) setState(() => _localIp = '未知');
    }
  }

  Future<void> _startDiscovery() async {
    _discovery = DeviceDiscovery(
      tcpPort: _settings.port,
      onFound: (d) {
        if (!mounted) return;
        _log('发现设备: ${d.name} (${d.ip}:${d.tcpPort})');
      },
      onChanged: () {
        if (!mounted) return;
        setState(() => _devices = _discovery!.liveDevices());
      },
    );
    try {
      await _discovery!.start();
      _log('设备发现已监听 UDP $discoverUdpPort');
    } catch (e) {
      _log('设备发现未启动: $e');
      // 允许稍后点「发现」时 ensureListening 重试
    }
  }

  @override
  void dispose() {
    _pullFields();
    unawaited(_settings.save());
    _sender?.requestStop();
    final recv = _receiver;
    _receiver = null;
    if (recv != null) unawaited(recv.stop());
    unawaited(_discovery?.stop());
    _logs.dispose();
    _portCtrl.dispose();
    _targetCtrl.dispose();
    _passwordCtrl.dispose();
    _httpUrlCtrl.dispose();
    super.dispose();
  }

  void _pullFields() {
    _settings.targetIp = _targetCtrl.text.trim();
    _settings.password = _passwordCtrl.text;
    if (_settings.role == 'receiver') {
      _settings.port = _port();
      _discovery?.setTcpPort(_settings.port);
    }
  }

  void _edit(VoidCallback fn) {
    setState(fn);
    _pullFields();
    unawaited(_settings.save());
  }

  void _log(String msg) {
    if (!mounted) return;
    final line = msg.endsWith('\n') ? msg.substring(0, msg.length - 1) : msg;
    final next = List<String>.from(_logs.value)..add(line);
    if (next.length > 400) next.removeRange(0, next.length - 400);
    _logs.value = next;
  }

  int _port() => int.tryParse(_portCtrl.text.trim()) ?? defaultPort;

  Future<void> _start() async {
    if (_busy) {
      _toast('已有任务在运行');
      return;
    }
    final port = _port();
    _pullFields();
    await _settings.save();
    _rate.updateLimit(_settings.rateMbps);
    // 宣告口始终是本机监听偏好，发送时端口框是对端口。
    _discovery?.setTcpPort(_settings.port);

    if (_settings.role == 'receiver') {
      await Permission.storage.request();
      setState(() => _busy = true);
      _receiver = TransferReceiver(
        port: port,
        saveDir: _settings.saveDir,
        log: _log,
        history: _history,
        rateLimiter: _rate,
        resume: _settings.resume,
        verify: _settings.verify,
        verifyAlgo: _settings.verifyAlgo,
        password: _settings.password,
        onProgress: _onProgress,
      );
      try {
        await _receiver!.start();
        _log('接收模式启动 (端口 $port)');
      } catch (e) {
        setState(() => _busy = false);
        _log('启动失败: $e');
      }
      return;
    }

    if (_settings.targetIp.isEmpty) {
      _toast('请输入目标 IP');
      return;
    }
    if (_queue.isEmpty) {
      _toast('请添加发送文件/文件夹');
      return;
    }
    if (_settings.encrypt && _settings.password.isEmpty) {
      _toast('加密需要密码');
      return;
    }
    setState(() => _busy = true);
    _sender = TransferSender(
      targetIp: _settings.targetIp,
      port: port,
      queue: List.from(_queue),
      log: _log,
      history: _history,
      rateLimiter: _rate,
      resume: _settings.resume,
      verify: _settings.verify,
      verifyAlgo: _settings.verifyAlgo,
      encrypt: _settings.encrypt,
      password: _settings.password,
      sync: _settings.sync,
      onProgress: _onProgress,
    );
    _log('发送 → ${_settings.targetIp}:$port  队列 ${_queue.length}');
    await _sender!.run();
    if (mounted) {
      setState(() {
        _busy = false;
        _progress = '';
        _ratio = null;
      });
    }
  }

  void _onProgress(String name, int done, int total, double mbps) {
    if (!mounted || total <= 0) return;
    setState(() {
      _ratio = done / total;
      _progress =
          '$name ${(100 * _ratio!).toStringAsFixed(0)}% ${mbps.toStringAsFixed(1)} MB/s';
    });
  }

  Future<void> _stop() async {
    _sender?.requestStop();
    await _receiver?.stop();
    _receiver = null;
    if (mounted) {
      setState(() {
        _busy = false;
        _progress = '';
        _ratio = null;
      });
    }
    _log('已停止');
  }

  Future<void> _addFiles() async {
    final files = await FilePicker.pickFiles();
    if (files.isEmpty) return;
    setState(() {
      for (final f in files) {
        if (f.path != null) _queue.add(f.path!);
      }
    });
  }

  Future<void> _addDir() async {
    final path = await FilePicker.getDirectoryPath();
    if (path == null) return;
    setState(() => _queue.add(path));
  }

  void _applyDevice(DiscoveredDevice d) {
    _targetCtrl.text = d.ip;
    _portCtrl.text = '${d.tcpPort}';
    _settings.targetIp = d.ip;
    unawaited(_settings.save());
  }

  DiscoveredDevice? get _selectedDevice {
    final ip = _targetCtrl.text.trim();
    for (final d in _devices) {
      if (d.ip == ip) return d;
    }
    return null;
  }

  Future<void> _pickDevice() async {
    if (_devices.isEmpty) {
      _toast('暂无设备，请先点发现');
      return;
    }
    final chosen = await showModalBottomSheet<DiscoveredDevice>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _DevicePickerSheet(
        devices: _devices,
        selectedIp: _targetCtrl.text.trim(),
      ),
    );
    if (chosen == null || !mounted) return;
    setState(() => _applyDevice(chosen));
  }

  Future<void> _discover() async {
    _log('正在发现设备...');
    try {
      await _discovery?.ensureListening();
    } catch (e) {
      _log('发现插座启动失败: $e');
      setState(() => _devices = []);
      return;
    }
    final list = await _discovery?.discoverOnce() ?? [];
    setState(() => _devices = list);
    if (list.isEmpty) {
      _log('未发现设备（本机 ${_localIp}，UDP $discoverUdpPort）');
      return;
    }
    _log('发现 ${list.length} 个设备');
    if (list.length == 1) {
      setState(() => _applyDevice(list.first));
      return;
    }
    await _pickDevice();
  }

  Future<void> _scanHttp() async {
    final url = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const ScanPage()),
    );
    if (url == null) return;
    _httpUrlCtrl.text = url;
    await _openHttp(url);
  }

  Future<void> _openHttp(String raw) async {
    final uri = ShareClient.tryParseShareUrl(raw);
    if (uri == null) {
      _toast('无效 HTTP 链接');
      return;
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => BrowserPage(rootUrl: uri)),
    );
  }

  void _toast(String m) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final receiving = _busy && _settings.role == 'receiver';

    return Scaffold(
      appBar: AppBar(
        title: const Text('局域网快传'),
        actions: [
          IconButton(
            tooltip: '历史',
            icon: const Icon(Icons.history_rounded),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => HistoryPage(history: _history)),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              children: [
                _statusBanner(cs),
                const SizedBox(height: 14),
                _section(
                  title: '角色',
                  child: SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(
                        value: 'receiver',
                        label: Text('接收'),
                        icon: Icon(Icons.download_rounded),
                      ),
                      ButtonSegment(
                        value: 'sender',
                        label: Text('发送'),
                        icon: Icon(Icons.upload_rounded),
                      ),
                    ],
                    selected: {_settings.role},
                    onSelectionChanged: !_ready || _busy
                  ? null
                  : (s) => _edit(() {
                        final role = s.first;
                        _settings.role = role;
                        if (role == 'receiver') {
                          _portCtrl.text = '${_settings.port}';
                        }
                      }),
                  ),
                ),
                _section(
                  title: '连接',
                  child: Column(
                    children: [
                      Row(
                        children: [
                          SizedBox(
                            width: 96,
                            child: TextField(
                              controller: _portCtrl,
                              decoration: const InputDecoration(labelText: '端口'),
                              keyboardType: TextInputType.number,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: TextField(
                              controller: _targetCtrl,
                              decoration: const InputDecoration(labelText: '目标 IP'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          FilledButton.tonalIcon(
                            onPressed: _ready ? _discover : null,
                            icon: const Icon(Icons.radar_rounded, size: 18),
                            label: const Text('发现'),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _DeviceField(
                              device: _selectedDevice,
                              count: _devices.length,
                              onTap: _ready ? _pickDevice : null,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                _section(
                  title: '选项',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _optChip('断点续传', _settings.resume,
                              (v) => _edit(() => _settings.resume = v)),
                          _optChip('差异同步', _settings.sync,
                              (v) => _edit(() => _settings.sync = v)),
                          _optChip('校验', _settings.verify,
                              (v) => _edit(() => _settings.verify = v)),
                          FilterChip(
                            label: Text(_settings.verifyAlgo.toUpperCase()),
                            selected: true,
                            onSelected: (_) => _edit(() {
                              _settings.verifyAlgo = _settings.verifyAlgo == 'md5'
                                  ? 'sha256'
                                  : 'md5';
                            }),
                          ),
                          _optChip('AES 加密', _settings.encrypt,
                              (v) => _edit(() => _settings.encrypt = v)),
                        ],
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _passwordCtrl,
                        decoration: const InputDecoration(labelText: '密码（加密/解密）'),
                        obscureText: true,
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Text(
                            '限速',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                          Expanded(
                            child: Slider(
                              value: _settings.rateMbps,
                              max: 200,
                              divisions: 40,
                              label: _settings.rateMbps <= 0
                                  ? '不限'
                                  : '${_settings.rateMbps.toStringAsFixed(0)} MB/s',
                              onChanged: (v) => setState(() {
                                _settings.rateMbps = v;
                                _rate.updateLimit(v);
                              }),
                              onChangeEnd: (_) {
                                _pullFields();
                                unawaited(_settings.save());
                              },
                            ),
                          ),
                          SizedBox(
                            width: 56,
                            child: Text(
                              _settings.rateMbps <= 0
                                  ? '不限'
                                  : _settings.rateMbps.toStringAsFixed(0),
                              textAlign: TextAlign.end,
                              style: Theme.of(context).textTheme.labelLarge,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (_settings.role == 'sender')
                  _section(
                    title: '发送队列',
                    trailing: Text(
                      '${_queue.length}',
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                            color: cs.primary,
                          ),
                    ),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            FilledButton.tonal(
                              onPressed: _addFiles,
                              child: const Text('文件'),
                            ),
                            const SizedBox(width: 8),
                            FilledButton.tonal(
                              onPressed: _addDir,
                              child: const Text('文件夹'),
                            ),
                            const Spacer(),
                            TextButton(
                              onPressed: _queue.isEmpty
                                  ? null
                                  : () => setState(() => _queue.clear()),
                              child: const Text('清空'),
                            ),
                          ],
                        ),
                        if (_queue.isEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 18),
                            child: Text(
                              '还没有待发送的文件',
                              style: Theme.of(context)
                                  .textTheme
                                  .bodyMedium
                                  ?.copyWith(color: const Color(0xFF627D98)),
                            ),
                          )
                        else
                          ..._queue.asMap().entries.map((e) {
                            final name = p.basename(e.value);
                            return ListTile(
                              contentPadding: EdgeInsets.zero,
                              dense: true,
                              leading: Icon(
                                _looksLikeFile(e.value)
                                    ? Icons.insert_drive_file_outlined
                                    : Icons.folder_outlined,
                                color: cs.primary,
                              ),
                              title: Text(name, overflow: TextOverflow.ellipsis),
                              subtitle: Text(
                                e.value,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 11),
                              ),
                              trailing: IconButton(
                                icon: const Icon(Icons.close_rounded),
                                onPressed: () =>
                                    setState(() => _queue.removeAt(e.key)),
                              ),
                            );
                          }),
                      ],
                    ),
                  ),
                _section(
                  title: 'HTTP 共享',
                  child: Column(
                    children: [
                      TextField(
                        controller: _httpUrlCtrl,
                        decoration: const InputDecoration(
                          labelText: '链接',
                          hintText: 'http://192.168.99.1:5000/',
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          FilledButton.icon(
                            onPressed: _scanHttp,
                            icon: const Icon(Icons.qr_code_scanner_rounded),
                            label: const Text('扫码'),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton(
                            onPressed: () => _openHttp(_httpUrlCtrl.text),
                            child: const Text('打开'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                _section(
                  title: '日志',
                  child: _LogPanel(logs: _logs),
                ),
              ],
            ),
          ),
          _bottomBar(cs, receiving),
        ],
      ),
    );
  }

  Widget _statusBanner(ColorScheme cs) {
    final save = _settings.saveDir.isEmpty
        ? '准备中…'
        : p.basename(_settings.saveDir);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFD9E2EC)),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: cs.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(Icons.wifi_tethering_rounded, color: cs.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _localIp,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.3,
                    color: Color(0xFF102A43),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '保存 · $save',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF627D98),
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (_busy)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: const Color(0xFFE3F8E8),
                borderRadius: BorderRadius.circular(999),
              ),
              child: const Text(
                '运行中',
                style: TextStyle(
                  color: Color(0xFF207A3C),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _bottomBar(ColorScheme cs, bool receiving) {
    return Material(
      elevation: 8,
      color: Colors.white,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_progress.isNotEmpty) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: _ratio,
                    minHeight: 6,
                    backgroundColor: const Color(0xFFE8EEF5),
                  ),
                ),
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _progress,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF334E68),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
              ],
              Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: FilledButton(
                      onPressed: !_ready || receiving ? null : _start,
                      child: Text(
                        _settings.role == 'receiver' ? '开始接收' : '开始发送',
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _busy ? _stop : null,
                      child: const Text('停止'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _section({
    required String title,
    required Widget child,
    Widget? trailing,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFFD9E2EC)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF486581),
                    letterSpacing: 0.2,
                  ),
                ),
                const Spacer(),
                ?trailing,
              ],
            ),
            const SizedBox(height: 10),
            child,
          ],
        ),
      ),
    );
  }

  Widget _optChip(String label, bool selected, ValueChanged<bool> onSelected) {
    return FilterChip(
      label: Text(label),
      selected: selected,
      onSelected: onSelected,
    );
  }

  static bool _looksLikeFile(String path) {
    final base = p.basename(path);
    final dot = base.lastIndexOf('.');
    return dot > 0 && dot < base.length - 1;
  }
}

class _LogPanel extends StatelessWidget {
  const _LogPanel({required this.logs});
  final ValueNotifier<List<String>> logs;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 200,
      decoration: BoxDecoration(
        color: const Color(0xFF102A43),
        borderRadius: BorderRadius.circular(10),
      ),
      clipBehavior: Clip.antiAlias,
      child: ValueListenableBuilder<List<String>>(
        valueListenable: logs,
        builder: (context, list, _) {
          if (list.isEmpty) {
            return const Center(
              child: Text(
                '等待操作…',
                style: TextStyle(color: Color(0xFF9FB3C8), fontSize: 13),
              ),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
            itemCount: list.length,
            itemBuilder: (_, i) {
              final line = list[list.length - 1 - i];
              return Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text(
                  line,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11.5,
                    height: 1.35,
                    color: Color(0xFFD9E2EC),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _DeviceField extends StatelessWidget {
  const _DeviceField({
    required this.device,
    required this.count,
    required this.onTap,
  });

  final DiscoveredDevice? device;
  final int count;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final label = device == null
        ? (count == 0 ? '点击发现后选择' : '已发现 $count 台 · 点选')
        : device!.name;
    final sub = device == null ? null : '${device!.ip}:${device!.tcpPort}';

    return Material(
      color: const Color(0xFFF5F7FA),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFD9E2EC)),
          ),
          child: Row(
            children: [
              Icon(Icons.devices_rounded, size: 18, color: cs.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF102A43),
                      ),
                    ),
                    if (sub != null)
                      Text(
                        sub,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFF627D98),
                        ),
                      ),
                  ],
                ),
              ),
              Icon(
                Icons.keyboard_arrow_down_rounded,
                color: onTap == null
                    ? const Color(0xFF9FB3C8)
                    : const Color(0xFF486581),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DevicePickerSheet extends StatelessWidget {
  const _DevicePickerSheet({
    required this.devices,
    required this.selectedIp,
  });

  final List<DiscoveredDevice> devices;
  final String selectedIp;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final maxH = MediaQuery.sizeOf(context).height * 0.72;

    return Align(
      alignment: Alignment.bottomCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxH),
        child: Material(
          color: Colors.white,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          clipBehavior: Clip.antiAlias,
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 10),
                Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: const Color(0xFFD9E2EC),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 12, 8),
                  child: Row(
                    children: [
                      Text(
                        '选择设备',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: cs.onSurface,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: cs.primary.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          '${devices.length}',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: cs.primary,
                          ),
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: '关闭',
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1, color: Color(0xFFE8EEF5)),
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
                    itemCount: devices.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 6),
                    itemBuilder: (ctx, i) {
                      final d = devices[i];
                      final selected = d.ip == selectedIp;
                      return Material(
                        color: selected
                            ? cs.primary.withValues(alpha: 0.08)
                            : const Color(0xFFF5F7FA),
                        borderRadius: BorderRadius.circular(14),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(14),
                          onTap: () => Navigator.pop(ctx, d),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                            child: Row(
                              children: [
                                Container(
                                  width: 40,
                                  height: 40,
                                  decoration: BoxDecoration(
                                    color: selected
                                        ? cs.primary.withValues(alpha: 0.18)
                                        : Colors.white,
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: selected
                                          ? cs.primary.withValues(alpha: 0.35)
                                          : const Color(0xFFD9E2EC),
                                    ),
                                  ),
                                  child: Icon(
                                    Icons.computer_rounded,
                                    size: 20,
                                    color: selected
                                        ? cs.primary
                                        : const Color(0xFF486581),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        d.name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 15,
                                          fontWeight: FontWeight.w700,
                                          color: Color(0xFF102A43),
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        '${d.ip}:${d.tcpPort}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 12,
                                          color: Color(0xFF627D98),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                if (selected)
                                  Icon(
                                    Icons.check_circle_rounded,
                                    color: cs.primary,
                                  )
                                else
                                  const Icon(
                                    Icons.chevron_right_rounded,
                                    color: Color(0xFF9FB3C8),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
