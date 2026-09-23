import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../http_share/share_client.dart';

class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  final _controller = MobileScannerController();
  bool _handled = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final b in capture.barcodes) {
      final raw = b.rawValue?.trim();
      if (raw == null) continue;
      final uri = ShareClient.tryParseShareUrl(raw);
      if (uri == null) continue;
      _handled = true;
      Navigator.of(context).pop(uri.toString());
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('扫描共享二维码')),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(controller: _controller, onDetect: _onDetect),
          const Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                '对准 PC「HTTP共享」二维码',
                style: TextStyle(color: Colors.white, backgroundColor: Colors.black54),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
