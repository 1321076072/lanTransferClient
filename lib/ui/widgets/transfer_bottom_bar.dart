import 'package:flutter/material.dart';

/// 进度条 + 开始/停止。
class TransferBottomBar extends StatelessWidget {
  const TransferBottomBar({
    super.key,
    required this.ready,
    required this.busy,
    required this.receiving,
    required this.isReceiver,
    required this.progress,
    required this.ratio,
    required this.onStart,
    required this.onStop,
  });

  final bool ready;
  final bool busy;
  final bool receiving;
  final bool isReceiver;
  final String progress;
  final double? ratio;
  final VoidCallback onStart;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
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
              if (progress.isNotEmpty) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: ratio,
                    minHeight: 6,
                    backgroundColor: const Color(0xFFE8EEF5),
                  ),
                ),
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    progress,
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
                      onPressed: !ready || receiving ? null : onStart,
                      child: Text(isReceiver ? '开始接收' : '开始发送'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: busy ? onStop : null,
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
}
