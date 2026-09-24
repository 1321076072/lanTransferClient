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
import 'widgets/device_picker.dart';
import 'widgets/log_panel.dart';
import 'widgets/save_dir_tile.dart';
import 'widgets/section_card.dart';
import 'widgets/status_banner.dart';
import 'widgets/transfer_bottom_bar.dart';

/// 主界面：角色 / 连接 / 保存目录 / 收发控制。
/// 协议细节在 net/ + protocol/；本页只编排 UI 与生命周期。
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

  Future<String> _defaultSaveDir() async {
    final docs = await getApplicationDocumentsDirectory(); 
    return p.join(docs.path, 'LanTransfer');
  }

  Future<void> _ensureSaveDir() async {
    if (_settings.saveDir.isEmpty) {
      _settings.saveDir = await _defaultSaveDir();
      await _settings.save();
      if (mounted) setState(() {});
    }
    try {
      await Directory(_settings.saveDir).create(recursive: true);
    } catch (_) {}
  }

  Future<bool> _requestSaveAccess() async {
    if (!Platform.isAndroid) return true;
    await Permission.storage.request();
    if (await Permission.manageExternalStorage.isGranted) return true;
    final manage = await Permission.manageExternalStorage.request();
    return manage.isGranted || await Permission.storage.isGranted;
  }

  Future<void> _applySaveDir(String path) async {
    final dir = Directory(path);
    try {
      await dir.create(recursive: true);
      final probe = File(p.join(path, '.lant_write_test'));
      await probe.writeAsString('ok', flush: true);
      await probe.delete();
    } catch (e) {
      _toast('目录不可写: $e');
      return;
    }
    setState(() => _settings.saveDir = path);
    await _settings.save();
    _log('保存目录 → $path');
  }

  Future<void> _pickSaveDir() async {
    if (_busy && _settings.role == 'receiver') {
      _toast('接收中不可改目录');
      return;
    }
    await _requestSaveAccess();
    final path = await FilePicker.getDirectoryPath(
      dialogTitle: '选择保存目录',
      initialDirectory:
          _settings.saveDir.isEmpty ? null : _settings.saveDir,
    );
    if (path == null || !mounted) return;
    await _applySaveDir(path);
  }

  Future<void> _resetSaveDir() async {
    if (_busy && _settings.role == 'receiver') {
      _toast('接收中不可改目录');
      return;
    }
    await _applySaveDir(await _defaultSaveDir());
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
      await _requestSaveAccess();
      await _ensureSaveDir();
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
    final ratio = (done / total).clamp(0.0, 1.0);
    setState(() {
      _ratio = ratio;
      _progress =
          '$name ${(100 * ratio).toStringAsFixed(0)}% ${mbps.toStringAsFixed(1)} MB/s';
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
      builder: (ctx) => DevicePickerSheet(
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
                StatusBanner(
                  localIp: _localIp,
                  saveDir: _settings.saveDir,
                  busy: _busy,
                  onTapSaveDir: _ready ? _pickSaveDir : null,
                ),
                const SizedBox(height: 14),
                SectionCard(
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
                SectionCard(
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
                            child: DeviceField(
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
                SectionCard(
                  title: '保存目录',
                  trailing: TextButton(
                    onPressed: _ready ? _resetSaveDir : null,
                    child: const Text('默认'),
                  ),
                  child: SaveDirTile(
                    path: _settings.saveDir,
                    onTap: _ready ? _pickSaveDir : null,
                  ),
                ),
                SectionCard(
                  title: '选项',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          OptChip('断点续传', _settings.resume,
                              (v) => _edit(() => _settings.resume = v)),
                          OptChip('差异同步', _settings.sync,
                              (v) => _edit(() => _settings.sync = v)),
                          OptChip('校验', _settings.verify,
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
                          OptChip('AES 加密', _settings.encrypt,
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
                  SectionCard(
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
                SectionCard(
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
                SectionCard(
                  title: '日志',
                  child: LogPanel(logs: _logs),
                ),
              ],
            ),
          ),
          TransferBottomBar(
            ready: _ready,
            busy: _busy,
            receiving: receiving,
            isReceiver: _settings.role == 'receiver',
            progress: _progress,
            ratio: _ratio,
            onStart: () => unawaited(_start()),
            onStop: () => unawaited(_stop()),
          ),
        ],
      ),
    );
  }

  static bool _looksLikeFile(String path) {
    final base = p.basename(path);
    final dot = base.lastIndexOf('.');
    return dot > 0 && dot < base.length - 1;
  }
}
