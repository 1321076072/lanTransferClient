import 'package:flutter/material.dart';

/// 顶部本机 IP + 保存路径；点击改目录。
class StatusBanner extends StatelessWidget {
  const StatusBanner({
    super.key,
    required this.localIp,
    required this.saveDir,
    required this.busy,
    required this.onTapSaveDir,
  });

  final String localIp;
  final String saveDir;
  final bool busy;
  final VoidCallback? onTapSaveDir;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final save = saveDir.isEmpty ? '准备中…' : saveDir;
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTapSaveDir,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
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
                      localIp,
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
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (busy)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
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
                )
              else
                Icon(
                  Icons.folder_open_rounded,
                  size: 20,
                  color: cs.primary.withValues(alpha: 0.7),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
