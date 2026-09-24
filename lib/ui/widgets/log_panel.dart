import 'package:flutter/material.dart';

/// 底部滚动日志；新行在上。
class LogPanel extends StatelessWidget {
  const LogPanel({super.key, required this.logs});

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
