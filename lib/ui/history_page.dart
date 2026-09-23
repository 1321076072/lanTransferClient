import 'package:flutter/material.dart';

import '../models/history.dart';

class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key, required this.history});
  final TransferHistory history;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('传输历史')),
      body: FutureBuilder(
        future: history.getAll(),
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final list = snap.data!;
          if (list.isEmpty) return const Center(child: Text('暂无记录'));
          return ListView.builder(
            itemCount: list.length,
            itemBuilder: (_, i) {
              final r = list[i];
              final size = r.size > 0
                  ? '${(r.size / 1024 / 1024).toStringAsFixed(1)} MB'
                  : '-';
              return ListTile(
                title: Text(r.filename),
                subtitle: Text(
                  '${r.time}  ${r.direction}  $size  ${r.status}'
                  '${r.verify.isNotEmpty ? '  校验:${r.verify}' : ''}'
                  '${r.encrypted ? '  加密' : ''}'
                  '${r.speed.isNotEmpty ? '  ${r.speed}' : ''}',
                ),
              );
            },
          );
        },
      ),
    );
  }
}
